import Foundation
import Flutter
import WidgetKit

/// Optional metadata channel. Main-thread channel registration and replies are
/// separate from utility-queue storage; the publisher is accessed only there.
final class LokalWidgetBridge: @unchecked Sendable {
  private enum Availability: String, Error {
    case notConfigured, invalidConfiguration, sharedContainerUnavailable
  }
  private enum ReplyValue: Sendable {
    case capability(available: Bool, revision: Int, reason: String?)
    case published(LokalWidgetPublication)
    case failure(code: String, message: String)
  }
  /// FlutterResult is not Sendable. Retain it behind one-shot delivery and
  /// invoke it only on the main queue; no untyped mutable payload crosses queues.
  private final class Reply: @unchecked Sendable {
    private let callback: FlutterResult
    private let lock = NSLock()
    private var delivered = false
    init(_ callback: @escaping FlutterResult) { self.callback = callback }
    func send(_ value: ReplyValue, reload: Bool = false) {
      lock.lock()
      guard !delivered else { lock.unlock(); return }
      delivered = true
      lock.unlock()
      DispatchQueue.main.async {
        dispatchPrecondition(condition: .onQueue(.main))
        switch value {
        case .capability(let available, let revision, let reason):
          if available {
            self.callback(["available": true, "committedRevision": revision])
          } else {
            self.callback(["available": false, "reason": reason ?? "unknown"])
          }
        case .published(let committed):
          // A reload request follows a real commit. WidgetKit controls actual
          // scheduling; a successful callback does not prove rendering.
          if reload { WidgetCenter.shared.reloadAllTimelines() }
          self.callback([
            "revision": committed.revision,
            "artworkByAlias": committed.artworkByAlias,
            "lastArtwork": committed.lastArtwork as Any? ?? NSNull(),
            "artworkDegraded": committed.artworkDegraded,
          ])
        case .failure(let code, let message):
          self.callback(FlutterError(code: code, message: message, details: nil))
        }
      }
    }
  }

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "app.lokal.mobile.widget-publication", qos: .utility)
  private var publisher: LokalWidgetPublisher?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "lokal/widgets", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      let reply = Reply(result)
      guard let self else {
        reply.send(.failure(code: "WIDGETS_UNAVAILABLE", message: "Widget publication is unavailable."))
        return
      }
      switch call.method {
      case "capability":
        self.queue.async { self.capability(reply) }
      case "publish":
        guard let args = call.arguments as? [String: Any],
              let metadata = args["metadata"] as? FlutterStandardTypedData,
              let images = args["artwork"] as? [String: FlutterStandardTypedData],
              metadata.data.count <= LokalWidgetSnapshot.maximumBytes,
              images.count <= LokalWidgetPublisher.maximumArtworkInputs else {
          reply.send(.failure(code: "INVALID_WIDGET_PUBLICATION", message: "Invalid widget metadata or artwork."))
          return
        }
        var bytes = 0
        for image in images.values {
          guard image.data.count <= LokalWidgetPublisher.maximumTotalInputBytes - bytes else {
            reply.send(.failure(code: "INVALID_WIDGET_PUBLICATION", message: "Widget artwork exceeds its byte budget."))
            return
          }
          bytes += image.data.count
        }
        let document = metadata.data
        let artwork = images.mapValues(\.data)
        let reload = args["reloadTimelines"] as? Bool ?? false
        self.queue.async {
          do {
            let committed = try self.resolvePublisher().publish(metadata: document, artworkByAlias: artwork)
            reply.send(.published(committed), reload: reload)
          } catch is Availability {
            reply.send(.failure(code: "WIDGETS_UNAVAILABLE", message: "This installation has no available widget shared container."))
          } catch {
            reply.send(.failure(code: "WIDGET_PUBLICATION_FAILED", message: "Widget metadata could not be published."))
          }
        }
      default:
        // The private protocol rejects unsupported operations explicitly. Avoid
        // importing Flutter's mutable ObjC sentinel into Swift 6 concurrency.
        reply.send(.failure(code: "UNSUPPORTED_WIDGET_METHOD", message: "Unknown widget publication operation."))
      }
    }
  }

  /// The optional identifier comes from this installed app's configuration,
  /// never a method argument. No fallback private-app container is invented.
  private func resolvePublisher() throws -> LokalWidgetPublisher {
    dispatchPrecondition(condition: .onQueue(queue))
    if let publisher { return publisher }
    guard let configured = Bundle.main.object(forInfoDictionaryKey: "LokalWidgetAppGroup") as? String,
          !configured.isEmpty else { throw Availability.notConfigured }
    guard configured.utf8.count <= 255,
          configured.range(of: "^group\\.[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
      throw Availability.invalidConfiguration
    }
    do {
      let store = try LokalWidgetStore.provisioned(groupIdentifier: configured, createIfMissing: true)
      let value = LokalWidgetPublisher(store: store)
      publisher = value
      return value
    } catch {
      throw Availability.sharedContainerUnavailable
    }
  }

  private func capability(_ reply: Reply) {
    do {
      let revision = try resolvePublisher().committedRevision()
      reply.send(.capability(available: true, revision: revision, reason: nil))
    } catch let reason as Availability {
      reply.send(.capability(available: false, revision: 0, reason: reason.rawValue))
    } catch {
      reply.send(.capability(available: false, revision: 0, reason: "storageNeedsRepair"))
    }
  }
}
