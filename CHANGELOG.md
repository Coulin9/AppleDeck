# 更新日志

## 0.1.1

### 新功能

- **共享剪贴板**：SteamOS 桌面模式和 Gamescope 游戏模式支持与 macOS 双向同步纯文本，
  单条最多 64 KiB。在 Mac 上复制后切回 VM 窗口即可在来宾内粘贴；在 SteamOS 内复制后
  切回 Mac 即可用 `⌘V` 粘贴。

### 图形性能

- 重构宿主与来宾间的图形 IPC：提交和 fence 改走共享内存环，渲染代理直接拉起各上下文
  worker，并用 Mach 信号量唤醒，去掉 render server 中转。
- 来宾通过映射的 virtio-gpu MMIO doorbell 页通知宿主（Neptune 与 Venus），不再每次
  走 execbuffer；内核新增 doorbell 页映射和计数器等待 ioctl。
- D3D12 fence：完成值由宿主写入共享槽位，`GetCompletedValue`、`SetEventOnCompletion`
  等在来宾本地完成；Win32 完成事件改由上下文状态页的完成队列统一投递，宿主侧 fence
  反馈由完成事件驱动，不再以 100 µs 周期轮询。
- D3D11 `FinishCommandList` 改为异步创建，不再等待宿主回复；资源类型、视图描述等不可变
  查询在来宾本地应答。
- 批量处理 `CopyDescriptorsSimple` 和 `CreateConstantBufferView`（例如 Nightreign
  每秒约百万次调用），并避免重叠的描述符拷贝合并到同一批次。

### 问题修复

- 修复《只狼》中多个延迟上下文以 `NO_OVERWRITE` 映射同一缓冲区时几何体闪烁的问题。
- 修复《只狼》转动视角时远景闪烁：延迟上下文中的查询结果只在命令列表执行后发布，
  不再返回过期的遮挡查询结果。
- 渲染 worker 退出或 VM 断开时立即将上下文标记为丢失，来宾可及时报告设备移除，
  不再等待心跳超时。
- 修复普通冷路径请求与主消费者竞争时 worker 被误判为协议违规并终止的问题。
- 修复内核 doorbell 对象被当作 GEM 对象使用时可能越界读取的问题。

### 构建

- Neptune 构建校验 `d3d12.dll` 的 `D3D12CreateDevice`（序号 101）和
  `D3D12GetDebugInterface`（序号 102）导出序号。
