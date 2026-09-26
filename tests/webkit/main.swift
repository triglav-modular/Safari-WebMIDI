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
// A loop: what reaches the destination comes back out of the source.
func plug(_ name: String) {
    var src = MIDIEndpointRef(), dst = MIDIEndpointRef()
    MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &src)
    let s = src
    MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &dst) { list, _ in MIDIReceivedEventList(s, list) }
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
    getURL: function (p) { return 'webmidi-ext://ext/' + (p || ''); }
  },
  storage: { local: {
    get: function (k) { var o = {}; if (k in __store) o[k] = JSON.parse(JSON.stringify(__store[k])); return Promise.resolve(o); },
    set: function (o) { Object.keys(o).forEach(function (k) { __store[k] = JSON.parse(JSON.stringify(o[k])); }); return Promise.resolve(); }
  } },
  tabs: {
    sendMessage: function (tab, msg, opts) { return window.webkit.messageHandlers.toTab.postMessage(msg); },
    query: function () { return Promise.resolve([{ id: 1 }]); }
  }
};
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
async function __toContent(msg) {
  for (const fn of __listeners) { const r = fn(msg, {}); if (r !== undefined) return await r; }
  return null;
}
"""

final class Harness: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, WKNavigationDelegate {
    var page: WKWebView!
    var background: WKWebView!
    var window: NSWindow!
    var backgroundReady = false

    func start() {
        let bcfg = WKWebViewConfiguration()
        bcfg.userContentController.addUserScript(WKUserScript(source: backgroundStub + backgroundJS,
                                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        bcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "native")
        bcfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "toTab")
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
        let errors = "addEventListener('error', e => webkit.messageHandlers.progress.postMessage('page error: ' + e.message + ' ' + e.filename + ':' + e.lineno)); addEventListener('unhandledrejection', e => webkit.messageHandlers.progress.postMessage('unhandled rejection: ' + (e.reason && (e.reason.name + ': ' + e.reason.message) || e.reason)));"
        ucc.addUserScript(WKUserScript(source: errors, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        ucc.addUserScript(WKUserScript(source: errors, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld))
        page = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: cfg)
        page.navigationDelegate = self
        // A window off every screen, ordered in but never seen and never
        // active: WebKit only takes real mouse and key events for a window
        // that is ordered in (one that is merely created gets none).
        window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1000, height: 700),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = page
        window.orderFrontRegardless()
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
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
            MIDIHub.shared.handle(m.body as? [String: Any] ?? [:]) { r in DispatchQueue.main.async { replyHandler(r, nil) } }
        case "toTab":
            page.callAsyncJavaScript("return await __toContent(msg)", arguments: ["msg": m.body], in: nil, in: contentWorld) { r in
                switch r {
                case .success(let v): replyHandler(v, nil)
                case .failure(let e): replyHandler(nil, "\(e)")
                }
            }
        case "harness":
            action(m.body as? [String: Any] ?? [:], replyHandler)
        default:
            replyHandler(nil, "unknown handler")
        }
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "progress" { if verbose { log("  .. \(m.body)") }; return }
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
        case "grants":
            background.callAsyncJavaScript("if (g !== null) __store.grants = JSON.parse(g); return JSON.stringify(__store.grants || {})",
                                           arguments: ["g": (a["set"] as? String) ?? NSNull()], in: nil, in: .page) { r in
                reply(try? r.get(), nil)
            }
        case "forget":
            // As the popup's Reset does: through setGrant, which tells the pages.
            background.callAsyncJavaScript("await setGrant(o, 'midi', null); await setGrant(o, 'sysex', null); return true",
                                           arguments: ["o": a["origin"] as? String ?? ""], in: nil, in: .page) { r in reply(try? r.get(), nil) }
        case "prompt":
            // What the prompt shows, read through the closed shadow root.
            page.callAsyncJavaScript("""
                const r = __roots[__roots.length - 1];
                const host = r && r.host;
                if (!host || !host.isConnected) return null;
                return { text: r.querySelector('.wrap').textContent, count: __roots.length };
                """, arguments: [:], in: nil, in: contentWorld) { r in reply(try? r.get(), nil) }
        case "untrustedClick":
            page.callAsyncJavaScript("""
                const r = __roots[__roots.length - 1];
                const b = r && r.querySelector(sel);
                if (!b) return false;
                b.disabled = false;
                b.click();
                b.dispatchEvent(new MouseEvent('click', { bubbles: true }));
                return true;
                """, arguments: ["sel": a["selector"] as? String ?? ".yes"], in: nil, in: contentWorld) { r in reply(try? r.get(), nil) }
        case "click":
            let sel = a["selector"] as? String ?? ".yes"
            // Waits out the prompt's half-second guard, then clicks for real.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.page.callAsyncJavaScript("""
                    const r = __roots[__roots.length - 1];
                    const b = r && r.querySelector(sel);
                    if (!b) return null;
                    const rc = b.getBoundingClientRect();
                    return [rc.x + rc.width / 2, rc.y + rc.height / 2];
                    """, arguments: ["sel": sel], in: nil, in: contentWorld) { r in
                    guard let p = (try? r.get()) as? [Double] else { reply(false, nil); return }
                    self.mouseClick(x: p[0], y: p[1])
                    reply(true, nil)
                }
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

    func mouseClick(x: Double, y: Double) {
        let local = NSPoint(x: x, y: page.isFlipped ? y : page.bounds.height - y)
        let at = page.convert(local, to: nil)
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
DispatchQueue.main.asyncAfter(deadline: .now() + (verbose ? 40 : 120)) { log("timeout: the page never reported"); exit(1) }
app.run()
