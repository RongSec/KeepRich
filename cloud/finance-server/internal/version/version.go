// Package version 版本号单一来源。
//
// 后端有多处需要"当前部署版本"（备份/快照 payload 的 appVersion 字段、
// /api/sync/status 的可观测信息），集中在这里避免散落字符串漂移。
// 发布时与 app/pubspec.yaml 的 version 保持一致。
package version

// App 后端版本号（语义化版本，不含 build number）
const App = "0.4.0"
