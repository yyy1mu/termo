//  Swift ↔ C 桥接头：暴露 SSH 引擎（russh）的 C 接口给 Swift。
//  在 project.yml 经 SWIFT_OBJC_BRIDGING_HEADER 指定。
#import "TermoSSHCore.h"     // SSH 引擎统一入口（termo_ssh_*，适配层直转 russh）
#import "TermoRusshCore.h"   // russh 直连接口与辅助类型
