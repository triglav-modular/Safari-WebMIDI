import AppKit
import CoreMIDI
import WebKit

// The extension end to end in WebKit, the engine Safari runs:
//   - shim.js and content.js exactly as built, content.js in an isolated
//     world at document start in every frame, as Safari injects it;
//   - background.js in a web view of its own, as Safari's background page;
//   - the browser.* calls between them carried by message handlers, and
//     sendNativeMessage answered by MIDIHub in this process;
//   - real (trusted) mouse and key events for the permission prompt.
// Safari's own plumbing (the extension store, sendNativeMessage's XPC) is
// the part this cannot reach; that is checked by hand in Safari.
//
//   webkit <built content.js> <background.js> <url> [grants-json]
// The page reports with webkit.messageHandlers.done.postMessage(results).

let args = CommandLine.arguments
let contentJS = try! String(contentsOfFile: args[1], encoding: .utf8)
let backgroundJS = try! String(contentsOfFile: args[2], encoding: .utf8)
let pageURL = URL(string: args[3])!
let seedGrants = args.count > 4 ? args[4] : "{}"
let extDir = args.count > 5 ? args[5] : ""
func log(_ s: String) { print(s); fflush(stdout) }
// FNV-1a, as __hash in the content stub.
func frameHash(_ s: String) -> Int {
    var h: UInt32 = 0x811c9dc5
    for b in s.utf8 { h ^= UInt32(b); h = h &* 0x01000193 }
    return Int(h % 2147483646) + 1
}
let verbose = ProcessInfo.processInfo.environment["WEBMIDI_VERBOSE"] != nil

// --- MIDI fixtures ---------------------------------------------------------------
var client = MIDIClientRef()
MIDIClientCreateWithBlock("webkit harness" as CFString, &client, nil)
var loops: [String: (MIDIEndpointRef, MIDIEndpointRef)] = [:]
// What reached a loop's destination, and when, so a test can time a send
// where it arrives, without the receive path's own delay.  Dated by uptime,
// not the wall clock: a CI runner's wall clock was corrected by tens of
// milliseconds mid-run, and arrivals just after a mark were dated before it.
func harnessMillis() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
// Each with the time CoreMIDI was given for it, in ms of host time: when a
// send was meant to go, whatever the runner's load made of its arrival.
var arrivals: [(Double, UInt32, Double)] = []
var sharedPackets = 0
let arrivalsLock = NSLock()
// A loop: what reaches the destination comes back out of the source.
func plug(_ name: String) {
    var src = MIDIEndpointRef(), dst = MIDIEndpointRef()
    MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &src)
    let s = src
    MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &dst) { list, _ in
        let now = harnessMillis()
        arrivalsLock.lock()
        // Every message in every packet: CoreMIDI can deliver several sends
        // in one packet, and a recorder that read only the first word of
        // each lost the rest.
        let wordsAt = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        for packet in list.unsafeSequence() {
            let n = Int(packet.pointee.wordCount)
            let words = UnsafeRawPointer(packet).advanced(by: wordsAt).assumingMemoryBound(to: UInt32.self)
            let stamp = MIDIHub.hostToNanos(packet.pointee.timeStamp) / 1e6
            var i = 0, messages = 0
            while i < n {
                arrivals.append((now, words[i], stamp))
                i += max(1, UMP.lengthInWords(words[i]))
                messages += 1
            }
            if messages > 1 { sharedPackets += 1 }
        }
        if arrivals.count > 20000 { arrivals.removeFirst(arrivals.count - 20000) }
        arrivalsLock.unlock()
        MIDIReceivedEventList(s, list)
    }
    loops[name] = (src, dst)
}
func unplug(_ name: String) {
    guard let (s, d) = loops.removeValue(forKey: name) else { return }
    MIDIEndpointDispose(s); MIDIEndpointDispose(d)
}
plug("WM Loop")

// --- the two web views ------------------------------------------------------------
let contentWorld = WKContentWorld.world(name: "webmidi-content")

let backgroundStub = """
var __store = {}, __listeners = [];
var browser = {
  runtime: {
    onMessage: { addListener: function (fn) { __listeners.push(fn); } },
    sendNativeMessage: function (app, req) { return window.webkit.messageHandlers.native.postMessage(req); },
    sendMessage: function (msg) { return window.webkit.messageHandlers.toPopup.postMessage(msg); },
    getURL: function (p) { return 'webmidi-ext://ext/' + (p || ''); }
  },
  storage: { local: {
    get: function (k) { var o = {}; if (k in __store) o[k] = JSON.parse(JSON.stringify(__store[k])); return Promise.resolve(o); },
    set: function (o) { Object.keys(o).forEach(function (k) { __store[k] = JSON.parse(JSON.stringify(o[k])); }); return Promise.resolve(); }
  } },
  tabs: {
    sendMessage: function (tab, msg, opts) {
      return window.webkit.messageHandlers.toTab.postMessage({ msg: msg, frameId: opts && opts.frameId !== undefined ? opts.frameId : null });
    },
    query: function () { return Promise.resolve([{ id: 1 }]); },
    onRemoved: { addListener: function () {} },
    onUpdated: { addListener: function () {} }
  },
  action: {
    openPopup: function () { return window.webkit.messageHandlers.openPopup.postMessage({}); },
    setBadgeText: function (o) { __badge = o.text; },
    setBadgeBackgroundColor: function () {},
    setIcon: function () { return Promise.resolve(); }
  },
  // A window of the extension's own: a web view beside the popup's.
  windows: {
    create: function (o) { return window.webkit.messageHandlers.openWindow.postMessage(o); },
    update: function () { return Promise.resolve({}); },
    remove: function () { return Promise.resolve(); }
  }
};
var __badge = '';
async function __deliver(msg, sender) {
  for (const fn of __listeners) { const r = fn(msg, sender); if (r !== undefined) return await r; }
  return null;
}
"""

let contentStub = """
var __listeners = [], __roots = [];
(function () {
  var attach = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function (o) { var r = attach.call(this, o); __roots.push(r); return r; };
})();
// Frame ids as Safari would give them: 0 for the top, and here a hash of
// the frame's URL for the rest, computed the same way by the harness.
function __hash(s) {
  var h = 0x811c9dc5;
  for (const b of new TextEncoder().encode(s)) { h ^= b; h = Math.imul(h, 0x01000193) >>> 0; }
  return (h % 2147483646) + 1;
}
var browser = { runtime: {
  getFrameId: function (el) { return __hash(new URL(el.getAttribute('src'), location.href).href); },
  sendMessage: function (msg) { return window.webkit.messageHandlers.toBg.postMessage(msg); },
  getURL: function (p) { return 'webmidi-ext://ext/' + p; },
  onMessage: { addListener: function (fn) { __listeners.push(fn); } }
} };
// Every frame says where it is as it loads, so a message for the whole tab
// reaches frames that have not spoken to the extension yet, as Safari's does.
window.webkit.messageHandlers.frameHello.postMessage(location.href);
async function __toContent(msg) {
  for (const fn of __listeners) { const r = fn(msg, {}); if (r !== undefined) return await r; }
  return null;
}
"""

// The toolbar popup, an extension page: its messages reach the background
// with the extension's own URL as the sender.
let popupStub = """
var __popupListeners = [];
var browser = {
  runtime: {
    sendMessage: function (m) { return window.webkit.messageHandlers.popupToBg.postMessage(m); },
    onMessage: { addListener: function (fn) { __popupListeners.push(fn); } }
  },
  tabs: {
    query: function () { return window.webkit.messageHandlers.popupTabs.postMessage({}); },
    get: function () { return window.webkit.messageHandlers.popupTabs.postMessage({}).then(function (t) { return t[0]; }); }
  }
};
function __popupDeliver(msg) { __popupListeners.forEach(function (fn) { fn(msg, { url: 'webmidi-ext://ext/background' }); }); return true; }
"""

final class Harness: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, WKNavigationDelegate {
    var page: WKWebView!
    var background: WKWebView!
    var window: NSWindow!
    var backgroundReady = false
    var popup: WKWebView!
    var popupWindow: NSWindow!
    var extWindow: WKWebView!
    var extWindowWindow: NSWindow!
    // Frames that have spoken, so a message for the whole tab reaches them all.
    var frames: [Int: WKFrameInfo] = [:]
    var nativeQueue: [([String: Any], (Any?, String?) -> Void)] = []
    var nativeBusy = false
    // Safari's limit: each request counts for about five seconds after it is
    // answered, and one that would take the count past 151 is refused
    // without reaching the extension (measured on Safari 27, 2026-09-26).
    static let safariLimit = 151, safariHold = 4.8
    static let safariRefusal = "Invalid call to runtime.sendNativeMessage(). The operation couldn\u{2019}t be completed. (SFErrorDomain error 3.)"
    var held: [Date] = []
    var refusals = 0, peak = 0, refuseNext = 0, sendFailures = 0
    var lastStarted = "(none)"
    // Popups and windows opened; with the toolbar's button hidden, openPopup
    // succeeds and opens nothing (what Safari does then is not known).
    var popupOpens = 0, windowOpens = 0, toolbarHidden = false
    // A background unloaded and loaded again keeps only its storage.
    var carriedStore: String? = nil
    var afterBackgroundLoad: (() -> Void)? = nil

    func nextNative() {
        guard !nativeBusy, !nativeQueue.isEmpty else { return }
        let (body, reply) = nativeQueue.removeFirst()
        let now = Date()
        held.removeAll { $0 <= now }
        if held.count >= Harness.safariLimit || refuseNext > 0 {
            if refuseNext > 0 { refuseNext -= 1 }
            refusals += 1
            reply(nil, Harness.safariRefusal)
            nextNative()
            return
        }
        nativeBusy = true
        held.append(.distantFuture)
        peak = max(peak, held.count)
        if verbose && ProcessInfo.processInfo.environment["WEBMIDI_TRACE"] != nil {
            log(String(format: "  native %.3f %@ queued=%d held=%d", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100), body["cmd"] as? String ?? "?", nativeQueue.count, held.count))
        }
        MIDIHub.shared.handle(body) { r in
            DispatchQueue.main.async {
                if let i = self.held.firstIndex(of: .distantFuture) { self.held[i] = Date().addingTimeInterval(Harness.safariHold) }
                if body["cmd"] as? String == "send", let failed = (r as? [String: Any])?["failed"] as? [Any] { self.sendFailures += failed.count }
                reply(r, nil)
                self.nativeBusy = false
                self.nextNative()
            }
        }
    }

    func start() {
        let bcfg = WKWebViewConfiguration()
        bcfg.userContentController.addUserScript(WKUserScript(source: backgroundStub + backgroundJS,
                                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        bcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "native")
        bcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "toTab")
        bcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "openPopup")
        bcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "openWindow")
        bcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "toPopup")

        let pcfg = WKWebViewConfiguration()
        pcfg.userContentController.addUserScript(WKUserScript(source: popupStub, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        pcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "popupToBg")
        pcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "popupTabs")
        popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 320), configuration: pcfg)
        popupWindow = offscreenWindow(for: popup, x: -4000)
        extWindow = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 320), configuration: pcfg)
        extWindowWindow = offscreenWindow(for: extWindow, x: -5000)
        background = WKWebView(frame: .zero, configuration: bcfg)
        background.navigationDelegate = self
        background.loadHTMLString("<!doctype html><title>background</title>", baseURL: URL(string: "https://background.invalid/"))

        let cfg = WKWebViewConfiguration()
        let ucc = cfg.userContentController
        ucc.addUserScript(WKUserScript(source: contentStub + contentJS, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false, in: contentWorld))
        ucc.addScriptMessageHandler(self, contentWorld: contentWorld, name: "toBg")
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "harness")
        ucc.add(self, contentWorld: .page, name: "done")
        ucc.add(self, contentWorld: .page, name: "progress")
        ucc.add(self, contentWorld: contentWorld, name: "progress")
        ucc.add(self, contentWorld: contentWorld, name: "frameHello")
        let errors = "addEventListener('error', e => webkit.messageHandlers.progress.postMessage('page error: ' + e.message + ' ' + e.filename + ':' + e.lineno)); addEventListener('unhandledrejection', e => webkit.messageHandlers.progress.postMessage('unhandled rejection: ' + (e.reason && (e.reason.name + ': ' + e.reason.message) || e.reason)));"
        ucc.addUserScript(WKUserScript(source: errors, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        ucc.addUserScript(WKUserScript(source: errors, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld))
        page = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: cfg)
        page.navigationDelegate = self
        window = offscreenWindow(for: page, x: -3000)
    }

    // Runs a script in the popup, again if the popup reloaded under it:
    // openPopup loads it afresh, as Safari opens a fresh popup, and a script
    // caught in that navigation ends without an answer.
    // `view` is the popup's, or the extension's window's.
    func popupEval(_ js: String, _ args: [String: Any], attempts: Int = 10, in view: WKWebView? = nil,
                   _ done: @escaping (Any?) -> Void) {
        (view ?? popup).callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { r in
            switch r {
            case .success(let v) where !(v is NSNull) && v != nil: done(v)
            default:
                if attempts <= 1 { done(nil); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.popupEval(js, args, attempts: attempts - 1, in: view, done) }
            }
        }
    }

    // A window off every screen, ordered in but never seen and never active:
    // WebKit only takes real mouse and key events for a window that is
    // ordered in (one that is merely created gets none).  Off every screen,
    // it counts as hidden, and WebKit throttles then suspends a hidden page
    // (a long quiet test stopped dead a second in), so occlusion detection is
    // turned off (WebKit SPI, test only).
    func offscreenWindow(for view: WKWebView, x: CGFloat) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: x, y: -3000, width: view.frame.width, height: view.frame.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.orderFrontRegardless()
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if view.responds(to: occlusion) {
            typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(view.method(for: occlusion), to: Set.self)(view, occlusion, false)
        }
        return w
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if w === background, backgroundReady, let store = carriedStore {
            carriedStore = nil
            background.callAsyncJavaScript("__store = JSON.parse(s); return true", arguments: ["s": store], in: nil, in: .page) { _ in
                self.afterBackgroundLoad?()
                self.afterBackgroundLoad = nil
            }
        }
        if w === background && !backgroundReady {
            backgroundReady = true
            background.callAsyncJavaScript("__store.grants = JSON.parse(g); return true", arguments: ["g": seedGrants],
                                           in: nil, in: .page) { _ in
                self.page.load(URLRequest(url: pageURL))
            }
        }
    }

    // --- routing ---------------------------------------------------------------------
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        if verbose && ProcessInfo.processInfo.environment["WEBMIDI_TRACE"] != nil {
            log("  >> \(m.name) main=\(m.frameInfo.isMainFrame) \(String(describing: m.body).prefix(160))")
        }
        switch m.name {
        case "toBg":
            if !m.frameInfo.isMainFrame, let u = m.frameInfo.request.url?.absoluteString { frames[frameHash(u)] = m.frameInfo }
            // The sender as Safari describes it, from the frame the message came from.
            let sender: [String: Any] = [
                "url": m.frameInfo.request.url?.absoluteString ?? "",
                "frameId": m.frameInfo.isMainFrame ? 0 : frameHash(m.frameInfo.request.url?.absoluteString ?? ""),
                "tab": ["id": 1, "url": page.url?.absoluteString ?? ""],
            ]
            background.callAsyncJavaScript("return await __deliver(msg, sender)",
                                           arguments: ["msg": m.body, "sender": sender], in: nil, in: .page) { r in
                if verbose && ProcessInfo.processInfo.environment["WEBMIDI_TRACE"] != nil {
                    log("  << \(String(describing: try? r.get()).prefix(200))")
                }
                switch r {
                case .success(let v): replyHandler(v, nil)
                case .failure(let e): replyHandler(nil, "\(e)")
                }
            }
        case "native":
            // One native request at a time, as Safari delivers them: measured
            // on Safari 27, never more than one in flight to the extension, so
            // a request waits while a long poll is open.  A harness that ran
            // them concurrently could not see a send held behind a receive.
            nativeQueue.append((m.body as? [String: Any] ?? [:], replyHandler))
            nextNative()
        case "toTab":
            // To the top frame, or with no frame named to every frame, the
            // first answer winning, as tabs.sendMessage does.
            let body = m.body as? [String: Any] ?? [:]
            let msg = body["msg"] ?? NSNull()
            var targets: [WKFrameInfo?] = [nil]
            if body["frameId"] as? Int == nil { targets += frames.values.map { Optional($0) } }
            var left = targets.count, answered = false
            for frame in targets {
                page.callAsyncJavaScript("return await __toContent(msg)", arguments: ["msg": msg], in: frame, in: contentWorld) { r in
                    left -= 1
                    if answered { return }
                    if case .success(let v) = r, v != nil, !(v is NSNull) { answered = true; replyHandler(v, nil) }
                    else if left == 0 { answered = true; replyHandler(nil, nil) }
                }
            }
        case "toPopup":
            // runtime.sendMessage from the background reaches the popup if it
            // is open, and the extension's window.
            extWindow.callAsyncJavaScript("return typeof __popupDeliver === 'function' ? __popupDeliver(msg) : null",
                                          arguments: ["msg": m.body], in: nil, in: .page) { _ in }
            popup.callAsyncJavaScript("return typeof __popupDeliver === 'function' ? __popupDeliver(msg) : null",
                                      arguments: ["msg": m.body], in: nil, in: .page) { r in
                if case .success(let v) = r, v != nil, !(v is NSNull) { replyHandler(v, nil) }
                else { replyHandler(nil, "Could not establish connection. Receiving end does not exist.") }
            }
        case "openPopup":
            if !toolbarHidden {
                popupOpens += 1
                popup.loadFileURL(URL(fileURLWithPath: extDir + "/popup.html"), allowingReadAccessTo: URL(fileURLWithPath: extDir))
            }
            replyHandler(true, nil)
        case "openWindow":
            windowOpens += 1
            var c = URLComponents(url: URL(fileURLWithPath: extDir + "/popup.html"), resolvingAgainstBaseURL: false)!
            c.query = URL(string: (m.body as? [String: Any])?["url"] as? String ?? "")?.query
            extWindow.loadFileURL(c.url!, allowingReadAccessTo: URL(fileURLWithPath: extDir))
            replyHandler(["id": windowOpens], nil)
        case "popupToBg":
            background.callAsyncJavaScript("return await __deliver(msg, sender)",
                                           arguments: ["msg": m.body, "sender": ["url": "webmidi-ext://ext/popup.html"]],
                                           in: nil, in: .page) { r in
                switch r {
                case .success(let v): replyHandler(v, nil)
                case .failure(let e): replyHandler(nil, "\(e)")
                }
            }
        case "popupTabs":
            replyHandler([["id": 1, "url": page.url?.absoluteString ?? "", "incognito": false]], nil)
        case "harness":
            action(m.body as? [String: Any] ?? [:], replyHandler)
        default:
            replyHandler(nil, "unknown handler")
        }
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "progress" {
            if let b = m.body as? String, b.hasPrefix("start: ") { lastStarted = String(b.dropFirst(7)) }
            if verbose { log("  .. \(m.body)") }
            return
        }
        if m.name == "frameHello" {
            if !m.frameInfo.isMainFrame, let u = m.frameInfo.request.url?.absoluteString { frames[frameHash(u)] = m.frameInfo }
            return
        }
        guard m.name == "done" else { return }
        var failed = 0
        for r in m.body as? [[Any]] ?? [] {
            let ok = r.count > 1 && (r[1] as? Bool ?? false)
            if !ok { failed += 1 }
            log((ok ? "ok    " : "FAIL  ") + "\(r.first ?? "")" + (!ok && r.count > 2 ? "\n      \(r[2])" : ""))
        }
        log(failed == 0 ? "ALL WEBKIT CHECKS PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }

    // --- things only the harness can do ----------------------------------------------
    func action(_ a: [String: Any], _ reply: @escaping (Any?, String?) -> Void) {
        switch a["action"] as? String {
        case "plug": plug(a["name"] as! String); reply(true, nil)
        case "unplug": unplug(a["name"] as! String); reply(true, nil)
        case "mark":
            // The harness's clock now, which the arrivals are dated by: a test
            // compares times on this one clock, never with the page's.
            reply(harnessMillis(), nil)
        case "arrivals":
            // [ms, first UMP word, CoreMIDI's time in ms] for everything that
            // reached a loop since `from` ms.
            let from = a["from"] as? Double ?? 0
            arrivalsLock.lock()
            let list = arrivals.filter { $0.0 >= from }.map { [$0.0, Double($0.1), $0.2] }
            arrivalsLock.unlock()
            reply(list, nil)
        case "safari":
            // Safari's count of native requests: refusals so far, the highest
            // count reached, and optionally refuse the next n outright.
            if let n = a["refuseNext"] as? Int { refuseNext = n }
            if a["reset"] as? Bool == true { refusals = 0; peak = 0; sendFailures = 0 }
            arrivalsLock.lock(); let shared = sharedPackets; arrivalsLock.unlock()
            reply(["refusals": refusals, "peak": peak, "sendFailures": sendFailures, "sharedPackets": shared], nil)
        case "grants":
            background.callAsyncJavaScript("if (g !== null) __store.grants = JSON.parse(g); return JSON.stringify(__store.grants || {})",
                                           arguments: ["g": (a["set"] as? String) ?? NSNull()], in: nil, in: .page) { r in
                reply(try? r.get(), nil)
            }
        case "forget":
            // As the popup's Reset does: through setGrant, which tells the pages.
            background.callAsyncJavaScript("for (const k of ['midi', 'sysex', 'dismissed', 'embargo']) await setGrant(o, k, null); return true",
                                           arguments: ["o": a["origin"] as? String ?? ""], in: nil, in: .page) { r in reply(try? r.get(), nil) }
        case "unloadBackground":
            // As Safari unloads an idle background: what it held in memory
            // goes, its storage stays, and a reply it owed is never sent.
            background.callAsyncJavaScript("return JSON.stringify(__store)", arguments: [:], in: nil, in: .page) { r in
                self.carriedStore = ((try? r.get()) as? String) ?? "{}"
                self.afterBackgroundLoad = { reply(true, nil) }
                self.background.loadHTMLString("<!doctype html><title>background</title>", baseURL: URL(string: "https://background.invalid/"))
            }
        case "toolbarClick":
            // The person opens the popup from the toolbar's button.
            popup.loadFileURL(URL(fileURLWithPath: extDir + "/popup.html"), allowingReadAccessTo: URL(fileURLWithPath: extDir))
            reply(true, nil)
        case "opens":
            if let h = a["toolbarHidden"] as? Bool { toolbarHidden = h }
            reply(["popup": popupOpens, "window": windowOpens], nil)
        case "badge":
            background.callAsyncJavaScript("return __badge", arguments: [:], in: nil, in: .page) { r in reply(try? r.get(), nil) }
        case "question":
            // What the toolbar popup (or with in: "window", the extension's
            // window) asks, once it has drawn; null if nothing.
            let view: WKWebView = a["in"] as? String == "window" ? extWindow : popup
            popupEval("""
                for (let i = 0; i < 20; i++) {
                    const a = document.getElementById('ask'), q = document.getElementById('askQuestion');
                    if (a && !a.hidden && q && q.textContent) return a.textContent;
                    await new Promise(r => setTimeout(r, 50));
                }
                return null;
                """, [:], attempts: a["expect"] as? Bool == false ? 1 : 10, in: view) { v in reply(v ?? NSNull(), nil) }
        case "decide":
            // A real click on the popup's Allow or Don't Allow, once it takes
            // clicks (a question just shown waits half a second).
            let sel = a["selector"] as? String ?? "#askAllow"
            let view: WKWebView = a["in"] as? String == "window" ? extWindow : popup
            popupEval("""
                for (let i = 0; i < 40; i++) {
                    const b = document.querySelector(sel), a = document.getElementById('ask');
                    if (b && a && !a.hidden && !b.disabled) {
                        const rc = b.getBoundingClientRect();
                        if (rc.width) return [rc.x + rc.width / 2, rc.y + rc.height / 2];
                    }
                    await new Promise(r => setTimeout(r, 50));
                }
                return null;
                """, ["sel": sel], in: view) { v in
                guard let p = v as? [Double] else { reply(false, nil); return }
                self.mouseClick(in: view, window: view.window!, x: p[0], y: p[1])
                reply(true, nil)
            }
        case "notice":
            // What the page's notice shows, read through its closed shadow root.
            page.callAsyncJavaScript("""
                const r = [...__roots].reverse().find(x => x.host && x.host.isConnected && x.host.localName === 'webmidi-notice');
                if (!r) return null;
                return { text: r.querySelector('.wrap').textContent, buttons: [...r.querySelectorAll('button')].map(b => b.textContent),
                         disabled: [...r.querySelectorAll('button')].map(b => b.disabled) };
                """, arguments: [:], in: nil, in: contentWorld) { r in reply((try? r.get()) ?? NSNull(), nil) }
        case "untrustedClick":
            page.callAsyncJavaScript("""
                const r = [...__roots].reverse().find(x => x.host && x.host.isConnected && x.host.localName === 'webmidi-notice');
                const bs = r ? [...r.querySelectorAll('button')] : [];
                for (const b of bs) { b.click(); b.dispatchEvent(new MouseEvent('click', { bubbles: true })); }
                return bs.length > 0;
                """, arguments: [:], in: nil, in: contentWorld) { r in reply(try? r.get(), nil) }
        case "noticeClick":
            // A real click on the notice's button named `button` (Not now if none).
            page.callAsyncJavaScript("""
                const r = [...__roots].reverse().find(x => x.host && x.host.isConnected && x.host.localName === 'webmidi-notice');
                const b = r && [...r.querySelectorAll('button')].find(b => b.textContent === name);
                if (!b) return null;
                const rc = b.getBoundingClientRect();
                return [rc.x + rc.width / 2, rc.y + rc.height / 2];
                """, arguments: ["name": a["button"] as? String ?? "Not now"], in: nil, in: contentWorld) { r in
                guard let p = (try? r.get()) as? [Double] else { reply(false, nil); return }
                self.mouseClick(in: self.page, window: self.window, x: p[0], y: p[1])
                reply(true, nil)
            }
        case "escape":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.key(code: 53, chars: "\u{1b}")
                reply(true, nil)
            }
        default:
            reply(nil, "unknown action")
        }
    }

    func mouseClick(in view: WKWebView, window: NSWindow, x: Double, y: Double) {
        let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        let at = view.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(e)
        }
    }
    func key(code: UInt16, chars: String) {
        window.makeFirstResponder(page)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            window.sendEvent(e)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = Harness()
harness.start()
DispatchQueue.main.asyncAfter(deadline: .now() + (verbose ? 40 : 180)) {
    log("timeout: the page never reported; the last test to start was \u{201C}\(harness.lastStarted)\u{201D}")
    exit(1)
}
app.run()
