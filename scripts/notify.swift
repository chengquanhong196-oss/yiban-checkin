#!/usr/bin/env swift
import UserNotifications

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: notify.swift <标题> <消息> [声音]")
    exit(1)
}

let title = args[1]
let message = args[2]
let sound = args.count > 3 ? args[3] : "default"

let semaphore = DispatchSemaphore(value: 0)

let center = UNUserNotificationCenter.current()
center.requestAuthorization(options: [.alert, .sound]) { granted, error in
    if !granted {
        print("通知权限未授权: \(error?.localizedDescription ?? "")")
        semaphore.signal()
        return
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = message
    content.sound = sound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(sound))

    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )

    center.add(request) { error in
        if let error = error {
            print("发送失败: \(error)")
        } else {
            print("发送成功")
        }
        semaphore.signal()
    }
}

semaphore.wait()
