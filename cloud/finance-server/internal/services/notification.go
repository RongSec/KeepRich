package services

import (
	"encoding/json"
	"log"
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

func (s *NotifyService) PushTo(uid uint64, typ, title, content, data string) error {
	n := models.Notification{
		UID:     uid,
		Type:    typ,
		Title:   title,
		Content: content,
		Data:    data,
	}
	if err := s.DB.Create(&n).Error; err != nil {
		return err
	}
	Hub.Push(uid, n)
	return nil
}
