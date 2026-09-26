//  Swift ↔ C 桥接头：暴露终端转码器的 C 接口给 Swift。
//  在 project.yml 经 SWIFT_OBJC_BRIDGING_HEADER 指定。
//  SSH 引擎（russh）的 C 接口改由 TermoEngine 包的 CTermoSSH 模块暴露（import CTermoSSH）。
#import "TermoTextTranscoder.h"
