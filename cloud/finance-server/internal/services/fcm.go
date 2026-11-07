// FCM 推送服务（占位）
//
// 启用步骤：
// 1. 在 backend 目录 go get firebase.google.com/go/v4
// 2. 在 Firebase 控制台创建项目，下载 service account JSON
// 3. 将 service account 路径放入 config.yaml 的 fcm.credentialsFile
// 4. 在 main.go 或 router 中初始化 fcm.NewService
// 5. 在超支/大件可购买提醒处调用 fcm.Send(token, title, body, data)

package services

import "fmt"

type FcmService struct {
	// creds *firebase.App
}

func NewFcmService() *FcmService {
	// 占位：未来初始化 Firebase Admin SDK
	// cred, _ := firebase.NewCredentialFromFile(...)
	// app, _ := firebase.NewApp(context.Background(), nil, cred)
	return &FcmService{}
}

type FcmMessage struct {
	Title string
	Body  string
	Data  map[string]string
	Token string
}

func (s *FcmService) Send(msg FcmMessage) error {
	// 占位：实际应调用 client.Send(ctx, message)
	fmt.Printf("[FCM 占位] 发送: title=%q, body=%q, token=%q\n", msg.Title, msg.Body, msg.Token)
	return nil
}
