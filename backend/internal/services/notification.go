package services

import (
	"encoding/json"
	"log"
	"strings"
	"sync"

	"github.com/gorilla/websocket"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
)

// wsClient 每连接一个写 goroutine + 发送队列
// gorilla/websocket 禁止并发写同一连接，Push 只入队，由 writePump 独占写出
type wsClient struct {
	conn *websocket.Conn
	send chan []byte
	once sync.Once
}

func (c *wsClient) close() {
	c.once.Do(func() {
		close(c.send)
		_ = c.conn.Close()
	})
}

// WSHub 按 uid 维护连接集合
type WSHub struct {
	mu      sync.RWMutex
	clients map[uint64]map[*wsClient]struct{}
}

var Hub = &WSHub{clients: make(map[uint64]map[*wsClient]struct{})}

// Register 注册连接并启动写泵
func (h *WSHub) Register(uid uint64, conn *websocket.Conn) *wsClient {
	client := &wsClient{conn: conn, send: make(chan []byte, 64)}
	h.mu.Lock()
	if _, ok := h.clients[uid]; !ok {
		h.clients[uid] = make(map[*wsClient]struct{})
	}
	h.clients[uid][client] = struct{}{}
	h.mu.Unlock()

	go client.writePump()
	return client
}

// writePump 独占写连接，避免并发写导致帧损坏/panic
func (c *wsClient) writePump() {
	for data := range c.send {
		if err := c.conn.WriteMessage(websocket.TextMessage, data); err != nil {
			log.Printf("[ws] write: %v", err)
			c.close()
			return
		}
	}
}

func (h *WSHub) Unregister(uid uint64, client *wsClient) {
	h.mu.Lock()
	if conns, ok := h.clients[uid]; ok {
		delete(conns, client)
		if len(conns) == 0 {
			delete(h.clients, uid)
		}
	}
	h.mu.Unlock()
	client.close()
}

// Push 推送消息到该用户的所有连接（非阻塞入队，队列满则丢弃最旧）
func (h *WSHub) Push(uid uint64, payload interface{}) {
	h.mu.RLock()
	conns := h.clients[uid]
	clients := make([]*wsClient, 0, len(conns))
	for c := range conns {
		clients = append(clients, c)
	}
	h.mu.RUnlock()
	if len(clients) == 0 {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		log.Printf("[ws] marshal: %v", err)
		return
	}
	for _, c := range clients {
		select {
		case c.send <- data:
		default:
			// 队列满：丢弃最旧一条再入队，防止慢客户端阻塞全站
			select {
			case <-c.send:
			default:
			}
			select {
			case c.send <- data:
			default:
			}
		}
	}
}

// NotifyService 通知落库 + 推送
type NotifyService struct{ DB *gorm.DB }

func NewNotifyService(db *gorm.DB) *NotifyService { return &NotifyService{DB: db} }

// renderTemplate 渲染通知模板：把 {占位符} 替换为 vars 对应值。
// 缺失的占位符保留原文（不 panic、不吞掉原文语义）；tpl 为空返回空串。
func renderTemplate(tpl string, vars map[string]string) string {
	if tpl == "" {
		return ""
	}
	var b strings.Builder
	for i := 0; i < len(tpl); {
		c := tpl[i]
		if c != '{' {
			b.WriteByte(c)
			i++
			continue
		}
		end := strings.IndexByte(tpl[i:], '}')
		if end < 0 {
			// 没有闭合的 { 直接照抄，不报错
			b.WriteString(tpl[i:])
			break
		}
		key := tpl[i+1 : i+end]
		if v, ok := vars[key]; ok {
			b.WriteString(v)
		} else {
			b.WriteString(tpl[i : i+end+1])
		}
		i += end + 1
	}
	return b.String()
}

// truncateRunes 按字符数截断，防止渲染后超列宽（标题 128 / 内容 512）
func truncateRunes(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max])
}

// loadSetting 读取用户某类型的通知设置；无记录/查询失败返回 nil（按默认走）。
// 设置表出错不应阻断推送，宁可降级为默认文案。
func (s *NotifyService) loadSetting(uid uint64, typ string) *models.NotificationSetting {
	var set models.NotificationSetting
	if err := s.DB.Where("user_id = ? AND type = ?", uid, typ).First(&set).Error; err != nil {
		return nil
	}
	return &set
}

// PushTo 推送通知给某用户：
//  1. 读该用户的 notification_settings，enabled=false 时整条跳过（不落库、不推送）；
//  2. 文案用用户模板（空则默认模板 DefaultNotifyTemplates[typ]），按 vars 渲染 {占位符}；
//  3. 落库 + WebSocket 推送（App 收到后弹手机系统通知栏）。
//
// vars 为模板变量（如 {"金额":"100","分类":"餐饮"}）；system 类以
// {标题}/{内容} 传入实际文案。缺变量的占位符保留原文。
//
// 取舍：五类通知都允许关闭（含家庭申请/结果）。关闭仅表示"不提醒"，
// 申请记录仍在家庭管理页可查，不丢流程，故不强制开启（默认全开）。
func (s *NotifyService) PushTo(uid uint64, typ string, vars map[string]string, data string) error {
	set := s.loadSetting(uid, typ)
	if set != nil && !set.Enabled {
		return nil
	}
	tpl := models.DefaultNotifyTemplates[typ]
	title, content := tpl.Title, tpl.Content
	if set != nil {
		if set.TitleTemplate != "" {
			title = set.TitleTemplate
		}
		if set.ContentTemplate != "" {
			content = set.ContentTemplate
		}
	}
	n := models.Notification{
		UID:     uid,
		Type:    typ,
		Title:   truncateRunes(renderTemplate(title, vars), 128),
		Content: truncateRunes(renderTemplate(content, vars), 512),
		Data:    data,
	}
	if err := s.DB.Create(&n).Error; err != nil {
		return err
	}
	Hub.Push(uid, n)
	return nil
}
