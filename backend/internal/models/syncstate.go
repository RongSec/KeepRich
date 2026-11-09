package models

// SyncState 云端快照同步的元数据（key-value 落盘表）。
//
// 为什么要落盘而不是只放内存（DESIGN §2.B.5）：
// 沙箱可能在用户刚写完账就被重启，进程内 dirty 标记随之丢失；重启后进程会误判
// "本地无新写"从而被云端旧快照覆盖 —— 直接违反"数据不能被乱动"的红线。
// 落盘后，重启第一件事就是"先推再比"。
//
// 注意：本表**不进快照 payload**（Tables() 清单里没有它），否则同步元数据会被
// 云端快照带着来回覆盖，dirty 永远归零。
type SyncState struct {
	Key   string `gorm:"primaryKey;size:64" json:"key"`
	Value string `gorm:"size:512" json:"value"`
}

// TableName 固定表名（GORM 默认会推导成 sync_states，与设计约定的 sync_state 不符）
func (SyncState) TableName() string { return "sync_state" }
