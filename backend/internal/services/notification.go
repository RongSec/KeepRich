package services

import (
	"encoding/json"
	"log"
	"sync"

	"github.com/gorilla/websocket"
	"github.com/yourname/family-finance/backend/internal/models"
	"gorm.io/gorm"
)

// WSHub 简易 WebSocket Hub：按 uid 维护连接集合
type WSHub struct {
	mu      sync.RWMutex
	clients map[uint64]map[*websocket.Conn]struct{}
}

var Hub = &WSHub{clients: make(map[uint64]map[*websocket.Conn]struct{})}

func (h *WSHub) Register(uid uint64, c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[uid]; !ok {
		h.clients[uid] = make(map[*websocket.Conn]struct{})
	}
	h.clients[uid][c] = struct{}{}
}

func (h *WSHub) Unregister(uid uint64, c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if conns, ok := h.clients[uid]; ok {
		delete(conns, c)
		if len(conns) == 0 {
			delete(h.clients, uid)
		}
	}
}

func (h *WSHub) Push(uid uint64, payload interface{}) {
	h.mu.RLock()
	conns := h.clients[uid]
	defer h.mu.RUnlock()
	if len(conns) == 0 {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		log.Printf("[ws] marshal: %v", err)
		return
	}
	for c := range conns {
		if err := c.WriteMessage(websocket.TextMessage, data); err != nil {
			log.Printf("[ws] write: %v", err)
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
