/*
 * Permissions Manager
 * Central manager for every permission the app needs
 */

import Foundation
import UIKit
import AVFoundation
import Photos

class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var allPermissionsGranted = false

    private init() {}

    // MARK: - Request all permissions

    func requestAllPermissions(completion: @escaping (Bool) -> Void) {
        print("📋 [Permissions] Requesting all permissions...")

        // Use DispatchGroup to wait for all permission requests to finish
        let group = DispatchGroup()
        var microphoneGranted = false
        var photoLibraryGranted = false

        // 1. Request microphone permission
        group.enter()
        requestMicrophonePermission { granted in
            microphoneGranted = granted
            group.leave()
        }

        // 2. Request photo-library permission
        group.enter()
        requestPhotoLibraryPermission { granted in
            photoLibraryGranted = granted
            group.leave()
        }

        // All permission requests finished
        group.notify(queue: .main) {
            let allGranted = microphoneGranted && photoLibraryGranted
            self.allPermissionsGranted = allGranted

            if allGranted {
                print("✅ [Permissions] All permissions granted")
            } else {
                print("⚠️ [Permissions] Some permissions were not granted:")
                print("   Microphone: \(microphoneGranted ? "✅" : "❌")")
                print("   Photo Library: \(photoLibraryGranted ? "✅" : "❌")")
            }

            completion(allGranted)
        }
    }

    // MARK: - Check all permission states

    func checkAllPermissions() -> Bool {
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        let microphoneGranted = microphoneStatus == .authorized
        let photoGranted = photoStatus == .authorized || photoStatus == .limited

        allPermissionsGranted = microphoneGranted && photoGranted
        return allPermissionsGranted
    }

    // MARK: - Microphone permission

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            print("✅ [Permissions] Microphone permission granted")
            completion(true)

        case .notDetermined:
            print("🎤 [Permissions] Request microphone permission...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    print(granted ? "✅ [Permissions] Microphone permission granted" : "❌ [Permissions] Microphone permission denied")
                    completion(granted)
                }
            }

        case .denied, .restricted:
            print("❌ [Permissions] Microphone permission denied or restricted")
            completion(false)

        @unknown default:
            completion(false)
        }
    }

    // MARK: - Photo-library permission

    private func requestPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch status {
        case .authorized, .limited:
            print("✅ [Permissions] Photo-library permission granted")
            completion(true)

        case .notDetermined:
            print("📷 [Permissions] Request photo-library permission...")
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                DispatchQueue.main.async {
                    let granted = newStatus == .authorized || newStatus == .limited
                    print(granted ? "✅ [Permissions] Photo-library permission granted" : "❌ [Permissions] Photo-library permission denied")
                    completion(granted)
                }
            }

        case .denied, .restricted:
            print("❌ [Permissions] Photo-library permission denied or restricted")
            completion(false)

        @unknown default:
            completion(false)
        }
    }

    // MARK: - Open system Settings

    func openSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            if UIApplication.shared.canOpenURL(settingsUrl) {
                UIApplication.shared.open(settingsUrl)
            }
        }
    }
}
