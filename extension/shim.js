// The Web MIDI API for Safari, in the page's own world.
//
// A port of Chromium's Blink module third_party/blink/renderer/modules/webmidi
// (navigator_web_midi.cc, midi_access_initializer.cc, midi_access.cc,
// midi_port.cc, midi_input.cc, midi_output.cc and the IDL files beside them),
// at the commit named in README.md.  Copyright 2013 The Chromium Authors and
// Google Inc.; use of the ported code is governed by a BSD-style license that
// can be found in third_party/chromium/LICENSE.
//
// Where Blink talks to the browser process over Mojo, this talks to
// content.js over a MessageChannel, and content.js to the extension's
// background page, which holds the permission and reaches CoreMIDI through
// the app extension.  Behaviour follows Chrome's rather than the letter of
// the spec wherever the two part, since that is what sites are tested with;
// the exceptions are marked.
(function () {
    'use strict';
    var root = window;
    // Tells content.js the inline copy ran, so it need not load the file.
    var me = document.currentScript;
    if (me && !me.src && document.documentElement) document.documentElement.setAttribute('data-webmidi', '');
    if (!root.isSecureContext) return;                  // [SecureContext]
    if (root.navigator && 'requestMIDIAccess' in root.navigator) return;

    var TOKEN = {};                                      // "Illegal constructor" unless ours

    // --- time --------------------------------------------------------------------
    // The native side keeps time by the wall clock, so page times cross as
    // wall-clock milliseconds.  performance.timeOrigin is fixed when the page
    // loads, and a wall clock corrected after that leaves it behind (by about
    // 40 ms in a CI run: sends went out that late, and arrivals were dated
    // that early).  So the offset is checked against the wall clock on every
    // use and taken up when it has moved more than 3 ms; Date.now() has whole
    // milliseconds, and a smaller threshold would move equal times apart.
    // Taken before the page's own scripts run, so a page cannot restyle time.
    var wallNow = Date.now, pageNow = performance.now.bind(performance), wallOffset = null;
    function pageToWall() {
        var fresh = wallNow() - pageNow();
        if (wallOffset === null) wallOffset = root.performance.timeOrigin;
        if (Math.abs(fresh - wallOffset) > 3) wallOffset = fresh;
        return wallOffset;
    }
    // A send's time, as wall-clock ms.  A time that comes again gets the wall
    // time it got before, even if the offset was taken up in between, so a
    // note-off and note-on given one time stay one time across a correction.
    var givenWall = new Map();
    function wallFor(ms) {
        var w = givenWall.get(ms);
        if (w === undefined) {
            w = pageToWall() + ms;
            givenWall.set(ms, w);
            if (givenWall.size > 1024) givenWall.delete(givenWall.keys().next().value);
        }
        return w;
    }

    // --- the channel to content.js -------------------------------------------
    var channel = null, nextId = 0, pending = new Map(), listeners = new Map();
    function connect() {
        if (channel) return channel;
        var mc = new MessageChannel();
        channel = mc.port1;
        channel.onmessage = function (e) {
            var m = e.data;
            if (!m) return;
            if (m.event) {
                var fn = listeners.get(m.event);
                if (fn) fn(m.value);
                return;
            }
            var p = pending.get(m.id);
            if (!p) return;
            pending.delete(m.id);
            if (m.ok) p.resolve(m.value);
            else p.reject(m.error || { name: 'AbortError', message: 'The MIDI system failed to start.' });
        };
        root.postMessage({ __webmidi_connect: 1 }, '*', [mc.port2]);
        return channel;
    }
    function call(op, args) {
        connect();
        return new Promise(function (resolve, reject) {
            var id = ++nextId;
            pending.set(id, { resolve: resolve, reject: reject });
            channel.postMessage({ id: id, op: op, args: args });
        });
    }
    function post(op, args) { connect(); channel.postMessage({ op: op, args: args }); }

    function domException(name, message) { return new DOMException(message, name); }
    function nextTask(fn) {
        // A task, as Blink's PostTask on kMiscPlatformAPI; not a microtask.
        var mc = new MessageChannel();
        mc.port1.onmessage = function () { mc.port1.close(); fn(); };
        mc.port2.postMessage(0);
    }

    // --- WebIDL helpers --------------------------------------------------------
    function brand(obj, Cls, what) {
        if (!(obj instanceof Cls) || !obj.__webmidi) {
            throw new TypeError("Illegal invocation" + (what ? ": '" + what + "'" : ''));
        }
    }
    // Makes a class's prototype members look like WebIDL's: enumerable, with
    // the interface's toStringTag.
    function idl(Cls, name) {
        var proto = Cls.prototype;
        Object.getOwnPropertyNames(proto).forEach(function (k) {
            if (k === 'constructor') return;
            var d = Object.getOwnPropertyDescriptor(proto, k);
            d.enumerable = true;
            Object.defineProperty(proto, k, d);
        });
        Object.defineProperty(proto, Symbol.toStringTag, { value: name, configurable: true });
        Object.defineProperty(Cls, 'name', { value: name, configurable: true });
    }
    function eventHandler(Cls, type, onSet) {
        var key = '__on' + type;
        var get = function () { brand(this, Cls, 'on' + type); return this[key] || null; };
        var set = function (f) {
            brand(this, Cls, 'on' + type);
            var fn = (typeof f === 'function' || (f && typeof f === 'object')) ? f : null;
            if (onSet) onSet.call(this, fn);
            if (this[key]) this.removeEventListener(type, this[key]);
            Object.defineProperty(this, key, { value: fn, writable: true, configurable: true });
            if (fn) EventTarget.prototype.addEventListener.call(this, type, fn);
        };
        Object.defineProperty(get, 'name', { value: 'get on' + type });
        Object.defineProperty(set, 'name', { value: 'set on' + type });
        Object.defineProperty(Cls.prototype, 'on' + type, { get: get, set: set, enumerable: true, configurable: true });
    }
    // WebIDL lengths: the count of required arguments.
    function lengths(obj, map) {
        Object.keys(map).forEach(function (k) {
            var target = k === '' ? obj : obj.prototype[k];
            Object.defineProperty(target, 'length', { value: map[k], configurable: true });
        });
    }
    function hidden(obj, props) {
        Object.keys(props).forEach(function (k) {
            Object.defineProperty(obj, k, { value: props[k], writable: true, configurable: true });
        });
    }

    // --- events ----------------------------------------------------------------
    class MIDIMessageEvent extends Event {
        constructor(type, init) {
            if (arguments.length < 1) throw new TypeError("Failed to construct 'MIDIMessageEvent': 1 argument required, but only 0 present.");
            if (init !== undefined && init !== null && typeof init !== 'object') {
                throw new TypeError("Failed to construct 'MIDIMessageEvent': The provided value is not of type 'MIDIMessageEventInit'.");
            }
            super(String(type), init || undefined);
            var data = init && init.data !== undefined ? init.data : null;
            if (data !== null && !(data instanceof Uint8Array)) {
                throw new TypeError("Failed to construct 'MIDIMessageEvent': Failed to read the 'data' property from 'MIDIMessageEventInit': The provided value is not of type 'Uint8Array'.");
            }
            hidden(this, { __data: data, __webmidi: true });
        }
        get data() { brand(this, MIDIMessageEvent, 'data'); return this.__data; }
    }
    idl(MIDIMessageEvent, 'MIDIMessageEvent');
    lengths(MIDIMessageEvent, { '': 1 });

    class MIDIConnectionEvent extends Event {
        constructor(type, init) {
            if (arguments.length < 1) throw new TypeError("Failed to construct 'MIDIConnectionEvent': 1 argument required, but only 0 present.");
            if (init !== undefined && init !== null && typeof init !== 'object') {
                throw new TypeError("Failed to construct 'MIDIConnectionEvent': The provided value is not of type 'MIDIConnectionEventInit'.");
            }
            super(String(type), init || undefined);
            var port = init && init.port !== undefined ? init.port : null;
            if (port !== null && !(port instanceof MIDIPort)) {
                throw new TypeError("Failed to construct 'MIDIConnectionEvent': Failed to read the 'port' property from 'MIDIConnectionEventInit': Failed to convert value to 'MIDIPort'.");
            }
            hidden(this, { __port: port, __webmidi: true });
        }
        get port() { brand(this, MIDIConnectionEvent, 'port'); return this.__port; }
    }
    idl(MIDIConnectionEvent, 'MIDIConnectionEvent');
    lengths(MIDIConnectionEvent, { '': 1 });

    function connectionEvent(port) {
        return new MIDIConnectionEvent('statechange', { port: port });   // bubbles: no
    }
    function messageEvent(bytes, timeStamp) {
        var e = new MIDIMessageEvent('midimessage', { data: bytes, bubbles: true });
        // Blink stamps the event with the MIDI time, not its creation time.
        Object.defineProperty(e, 'timeStamp', { value: timeStamp, configurable: true });
        return e;
    }

    // --- MIDIPort (midi_port.cc) -----------------------------------------------
    class MIDIPort extends EventTarget {
        constructor(token) {
            if (token !== TOKEN) throw new TypeError('Illegal constructor');
            super();
        }
        get connection() { brand(this, MIDIPort, 'connection'); return this.__connection; }
        get id() { brand(this, MIDIPort, 'id'); return this.__id; }
        get manufacturer() { brand(this, MIDIPort, 'manufacturer'); return this.__manufacturer; }
        get name() { brand(this, MIDIPort, 'name'); return this.__name; }
        get state() { brand(this, MIDIPort, 'state'); return this.__state; }
        get type() { brand(this, MIDIPort, 'type'); return this.__type; }
        get version() { brand(this, MIDIPort, 'version'); return this.__version; }
        open() {
            try { brand(this, MIDIPort, 'open'); } catch (e) { return Promise.reject(e); }
            var self = this;
            if (this.__connection === 'open') return Promise.resolve(this);
            this.__runningOpen++;
            return new Promise(function (resolve) {
                nextTask(function () { self.__openAsynchronously(); resolve(self); });
            });
        }
        close() {
            try { brand(this, MIDIPort, 'close'); } catch (e) { return Promise.reject(e); }
            var self = this;
            if (this.__connection === 'closed') return Promise.resolve(this);
            return new Promise(function (resolve) {
                nextTask(function () {
                    self.__setStates(self.__state, 'closed');
                    resolve(self);
                });
            });
        }
    }
    eventHandler(MIDIPort, 'statechange');
    idl(MIDIPort, 'MIDIPort');
    lengths(MIDIPort, { '': 0 });

    function initPort(port, access, info, type) {
        hidden(port, {
            __webmidi: true, __access: access, __type: type,
            __id: String(info.id), __manufacturer: info.manufacturer || '', __name: info.name || '',
            __version: info.version || '', __state: 'connected', __connection: 'closed',
            __runningOpen: 0
        });
    }
    // The implicit open that sending, or listening for messages, performs.
    MIDIPort.prototype.__open = function () {
        if (this.__connection === 'open' || this.__runningOpen) return;
        var self = this;
        this.__runningOpen++;
        nextTask(function () { self.__openAsynchronously(); });
    };
    MIDIPort.prototype.__openAsynchronously = function () {
        this.__runningOpen--;
        this.__didOpen(this.__state === 'connected');
        this.__setStates(this.__state, this.__state === 'disconnected' ? 'pending' : 'open');
    };
    MIDIPort.prototype.__didOpen = function () {};
    MIDIPort.prototype.__setStates = function (state, connection) {
        if (this.__state === state && this.__connection === connection) return;
        this.__state = state;
        this.__connection = connection;
        this.dispatchEvent(connectionEvent(this));
        this.__access.dispatchEvent(connectionEvent(this));
    };
    // The device came or went (MIDIPort::SetState).
    MIDIPort.prototype.__setState = function (state) {
        if (state === 'disconnected') {
            this.__setStates('disconnected', this.__connection === 'closed' ? 'closed' : 'pending');
        } else if (this.__connection === 'pending') {
            this.__state = 'connected';          // open() dispatches the one event
            this.__open();
        } else {
            this.__setStates('connected', this.__connection);
        }
    };
    [MIDIPort.prototype].forEach(function (p) {
        ['__open', '__openAsynchronously', '__didOpen', '__setStates', '__setState'].forEach(function (k) {
            Object.defineProperty(p, k, { enumerable: false });
        });
    });

    // --- MIDIInput (midi_input.cc) ---------------------------------------------
    class MIDIInput extends MIDIPort {
        constructor(token) { super(token); }
        addEventListener(type, listener, options) {
            EventTarget.prototype.addEventListener.call(this, type, listener, options);
            if (String(type) === 'midimessage' && this instanceof MIDIInput) this.__open();
        }
    }
    eventHandler(MIDIInput, 'midimessage', function () { this.__open(); });
    idl(MIDIInput, 'MIDIInput');
    lengths(MIDIInput, { '': 0 });
    // Not part of the interface: the override is how Blink's
    // AddedEventListener hook shows through, so keep it off enumeration.
    Object.defineProperty(MIDIInput.prototype, 'addEventListener', { enumerable: false });
    MIDIInput.prototype.__receive = function (bytes, timeStamp) {
        if (!bytes.length || this.__connection !== 'open') return;
        if (bytes[0] === 0xf0 && !this.__access.__sysex) return;
        this.dispatchEvent(messageEvent(bytes, timeStamp));
    };

    // --- MIDIOutput (midi_output.cc) -------------------------------------------
    // MessageValidator, with Blink's messages.
    function validate(data, sysexEnabled) {
        var offset = 0, n = data.length;
        function at() { return 'at index ' + offset + ' (' + data[offset] + ').'; }
        function isReserved(b) { return b === 0xf4 || b === 0xf5 || b === 0xf9 || b === 0xfd; }
        function acceptRealTime() {
            for (; offset < n; offset++) {
                if (data[offset] >= 0xf8 && !isReserved(data[offset])) continue;
                return true;
            }
            return false;
        }
        var CHANNEL = [3, 3, 3, 3, 2, 2, 3], SYSTEM = [2, 3, 2, 0, 0, 1, 0];
        while (offset < n && acceptRealTime()) {
            var b = data[offset];
            if (!(b & 0x80)) throw new TypeError('Running status is not allowed ' + at());
            if (b === 0xf7) throw new TypeError('Unexpected end of system exclusive message ' + at());
            if (isReserved(b)) throw new TypeError('Reserved status is not allowed ' + at());
            if (b === 0xf0) {
                if (!sysexEnabled) throw domException('NotAllowedError', 'System exclusive message is not allowed ' + at());
                var ended = false;
                for (offset++; offset < n; offset++) {
                    var c = data[offset];
                    if (isReserved(c)) break;
                    if (c >= 0xf8) continue;
                    if (c === 0xf7) { offset++; ended = true; break; }
                    if (c & 0x80) break;
                }
                if (!ended) {
                    if (offset >= n) throw new TypeError('System exclusive message is not ended by end of system exclusive message.');
                    throw new TypeError('System exclusive message contains a status byte ' + at());
                }
                continue;
            }
            var length = b >= 0xf0 ? SYSTEM[b - 0xf1] : CHANNEL[(b >> 4) - 8];
            offset++;
            if (length === 1) continue;
            var ok = false;
            for (var count = 1; offset < n; offset++) {
                var d = data[offset];
                if (isReserved(d)) break;
                if (d >= 0xf8) continue;
                if (d & 0x80) break;
                if (++count === length) { offset++; ok = true; break; }
            }
            if (!ok) {
                if (offset >= n) throw new TypeError('Message is incomplete.');
                throw new TypeError('Unexpected status byte ' + at());
            }
        }
    }
    function toUint32(v) {
        var x = Number(v);
        if (!isFinite(x)) return 0;
        x = Math.trunc(x) % 4294967296;
        return x < 0 ? x + 4294967296 : x;
    }
    // The send(Uint8Array) and send(sequence<unsigned long>) overloads.
    function bytesOf(data) {
        if (data instanceof Uint8Array) return new Uint8Array(data);
        if (data === null || (typeof data !== 'object' && typeof data !== 'function') ||
            typeof data[Symbol.iterator] !== 'function') {
            throw new TypeError("Failed to execute 'send' on 'MIDIOutput': The provided value cannot be converted to a sequence.");
        }
        var values = [], i = 0;
        for (var v of data) {
            var u = toUint32(v);
            if (u > 0xff) throw new TypeError('The value at index ' + i + ' (' + u + ') is greater than 0xFF.');
            values.push(u);
            i++;
        }
        return new Uint8Array(values);
    }

    class MIDIOutput extends MIDIPort {
        constructor(token) { super(token); }
        send(data, timestamp) {
            brand(this, MIDIOutput, 'send');
            if (arguments.length < 1) throw new TypeError("Failed to execute 'send' on 'MIDIOutput': 1 argument required, but only 0 present.");
            var bytes = bytesOf(data);
            var ms = 0;
            if (timestamp !== undefined) {
                ms = Number(timestamp);
                if (!isFinite(ms)) throw new TypeError("Failed to execute 'send' on 'MIDIOutput': The provided double value is non-finite.");
            }
            // Blink: 0 means now; anything else is relative to the time origin.
            var wall = ms === 0 ? 0 : wallFor(ms);
            // Implicit open, even when the data turns out to be invalid.
            this.__open();
            validate(bytes, this.__access.__sysex);
            if (this.__runningOpen) this.__pendingData.push([bytes, wall]);
            else this.__access.__sendMIDIData(this, bytes, wall);
        }
        // Not in Chrome (its IDL still has "TODO: implement void clear()");
        // the spec and Firefox have it.  Drops what has not been sent yet.
        clear() {
            brand(this, MIDIOutput, 'clear');
            this.__pendingData = [];
            hub.clear(this.__id);
        }
    }
    idl(MIDIOutput, 'MIDIOutput');
    lengths(MIDIOutput, { '': 0, send: 1 });
    MIDIOutput.prototype.__didOpen = function (opened) {
        var queued = this.__pendingData;
        this.__pendingData = [];
        if (!opened) return;
        var self = this;
        queued.forEach(function (q) { self.__access.__sendMIDIData(self, q[0], q[1]); });
    };
    Object.defineProperty(MIDIOutput.prototype, '__didOpen', { enumerable: false });

    // --- the maps (midi_port_map.h) --------------------------------------------
    function makeMap(name) {
        class PortMap {
            constructor(token) {
                if (token !== TOKEN) throw new TypeError('Illegal constructor');
                hidden(this, { __webmidi: true, __map: new Map() });
            }
            get size() { brand(this, PortMap, 'size'); return this.__map.size; }
            entries() { brand(this, PortMap, 'entries'); return this.__map.entries(); }
            keys() { brand(this, PortMap, 'keys'); return this.__map.keys(); }
            values() { brand(this, PortMap, 'values'); return this.__map.values(); }
            get(key) { brand(this, PortMap, 'get'); return this.__map.get(String(key)); }
            has(key) { brand(this, PortMap, 'has'); return this.__map.has(String(key)); }
            forEach(callback, thisArg) {
                brand(this, PortMap, 'forEach');
                if (typeof callback !== 'function') throw new TypeError("Failed to execute 'forEach' on '" + name + "': The callback provided as parameter 1 is not a function.");
                var self = this;
                this.__map.forEach(function (v, k) { callback.call(thisArg, v, k, self); });
            }
        }
        idl(PortMap, name);
        lengths(PortMap, { '': 0, forEach: 1 });
        Object.defineProperty(PortMap.prototype, Symbol.iterator, {
            value: PortMap.prototype.entries, writable: true, configurable: true
        });
        return PortMap;
    }
    var MIDIInputMap = makeMap('MIDIInputMap');
    var MIDIOutputMap = makeMap('MIDIOutputMap');
    // CreatePortMap: a new map each time, of the ports that are not
    // disconnected; ports sharing an id make it empty.
    function portMap(Cls, list) {
        var map = new Cls(TOKEN), ids = new Set(), ports = [];
        list.forEach(function (p) {
            if (p.__state !== 'disconnected') { ports.push(p); ids.add(p.__id); }
        });
        if (ports.length === ids.size) ports.forEach(function (p) { map.__map.set(p.__id, p); });
        return map;
    }

    // --- MIDIAccess (midi_access.cc) -------------------------------------------
    class MIDIAccess extends EventTarget {
        constructor(token) {
            if (token !== TOKEN) throw new TypeError('Illegal constructor');
            super();
        }
        get inputs() { brand(this, MIDIAccess, 'inputs'); return portMap(MIDIInputMap, this.__inputs); }
        get outputs() { brand(this, MIDIAccess, 'outputs'); return portMap(MIDIOutputMap, this.__outputs); }
        get sysexEnabled() { brand(this, MIDIAccess, 'sysexEnabled'); return this.__sysex; }
    }
    eventHandler(MIDIAccess, 'statechange');
    idl(MIDIAccess, 'MIDIAccess');
    lengths(MIDIAccess, { '': 0 });

    function newAccess(sysex, list) {
        var access = new MIDIAccess(TOKEN);
        hidden(access, { __webmidi: true, __sysex: sysex, __inputs: [], __outputs: [] });
        (list.inputs || []).forEach(function (info) { addPort(access, 'input', info, false); });
        (list.outputs || []).forEach(function (info) { addPort(access, 'output', info, false); });
        return access;
    }
    function addPort(access, type, info, announce) {
        var port = new (type === 'input' ? MIDIInput : MIDIOutput)(TOKEN);
        initPort(port, access, info, type);
        if (type === 'output') hidden(port, { __pendingData: [] });
        (type === 'input' ? access.__inputs : access.__outputs).push(port);
        // DidAddInputPort: the event goes to the access only.
        if (announce) access.dispatchEvent(connectionEvent(port));
        return port;
    }
    MIDIAccess.prototype.__sendMIDIData = function (port, bytes, wall) {
        if (!bytes.length) return;
        hub.send(port.__id, bytes, wall);
    };
    // The system's port list now; ports are matched by id and never removed.
    MIDIAccess.prototype.__update = function (list) {
        var self = this;
        [['input', this.__inputs, list.inputs || []], ['output', this.__outputs, list.outputs || []]].forEach(function (s) {
            var now = new Map();
            s[2].forEach(function (info) { now.set(String(info.id), info); });
            s[1].forEach(function (port) {
                var there = now.has(port.__id);
                if (there && port.__state === 'disconnected') port.__setState('connected');
                if (!there && port.__state !== 'disconnected') port.__setState('disconnected');
                now.delete(port.__id);
            });
            now.forEach(function (info) { addPort(self, s[0], info, true); });
        });
    };
    ['__sendMIDIData', '__update'].forEach(function (k) {
        Object.defineProperty(MIDIAccess.prototype, k, { enumerable: false });
    });

    // --- the hub: one per document, for every MIDIAccess in it ------------------
    var accesses = [];
    var hub = {
        gen: null, cursor: -1, polling: false, queue: [], inflight: false, unacked: 0,
        // MIDIDispatcher's kMaxUnacknowledgedBytesSent.
        MAX_UNACKED: 10 * 1024 * 1024,
        send: function (id, bytes, wall) {
            if (this.MAX_UNACKED - this.unacked < bytes.length) return;
            this.lastSend = root.performance.now();
            this.unacked += bytes.length;
            this.queue.push([id, bytes, wall]);
            this.flush();
        },
        // What clear() takes out of the queue was counted against
        // MAX_UNACKED and will never be acknowledged, so it is given back;
        // otherwise a few clears of large sysex left every later send
        // dropped for good.
        clear: function (id) {
            var self = this;
            this.queue = this.queue.filter(function (q) {
                if (q[0] !== id) return true;
                self.unacked -= q[1].length;
                return false;
            });
            post('clear', { port: id });
        },
        // One batch in flight at a time, so the order is the order sent.
        flush: function () {
            if (this.inflight || !this.queue.length) return;
            var batch = this.queue, self = this;
            this.queue = [];
            this.inflight = true;
            var size = batch.reduce(function (a, q) { return a + q[1].length; }, 0);
            call('send', { msgs: batch }).catch(function () {}).then(function () {
                self.unacked -= size;
                self.inflight = false;
                self.flush();
            });
        },
        ports: function () {
            var self = this;
            return call('ports').then(function (list) {
                self.gen = list.gen;
                accesses.forEach(function (a) { a.__update(list); });
                return list;
            });
        },
        // Safari delivers the extension's native requests one at a time, so a
        // receive left open holds every send behind it: a one-second long
        // poll put note-ons up to a second late (the 218e calibration sweep,
        // 2026-09-26).  And it allows only so many requests in a few seconds
        // (background.js), so receiving cannot simply run all the time.
        // While some input is open, a page that has sent in the last
        // SENT_LATELY ms checks without waiting every LISTEN_EVERY ms, so its
        // sends never queue behind a receive; one that only listens waits up
        // to LISTEN_WAIT ms for input, so input arrives as it comes.  Both
        // come to about fifteen requests a second.  With no input open, a
        // check every IDLE_EVERY ms notices ports coming and going.
        LISTEN_EVERY: 50,
        LISTEN_WAIT: 45,
        SENT_LATELY: 2000,
        IDLE_EVERY: 250,
        lastSend: -Infinity,
        listening: function () {
            return accesses.some(function (a) {
                return a.__inputs.some(function (p) { return p.__connection === 'open'; });
            });
        },
        poll: function () {
            if (this.polling) return;
            this.polling = true;
            var self = this;
            function sending() { return root.performance.now() - self.lastSend < self.SENT_LATELY; }
            function later() {
                if (!self.listening()) root.setTimeout(next, self.IDLE_EVERY);
                else if (sending()) root.setTimeout(next, self.LISTEN_EVERY);
                else next();
            }
            function next() {
                var wait = self.listening() && !sending() ? self.LISTEN_WAIT : 0;
                call('recv', { since: self.cursor, gen: self.gen, wait: wait }).then(function (r) {
                    self.cursor = r.seq;
                    var origin = pageToWall();
                    (r.events || []).forEach(function (ev) {
                        var id = String(ev[0]), ts = ev[2] - origin;
                        accesses.forEach(function (a) {
                            a.__inputs.forEach(function (p) {
                                if (p.__id === id) p.__receive(new Uint8Array(ev[1]), ts);
                            });
                        });
                    });
                    if (r.gen !== self.gen) return self.ports().then(later, later);
                    later();
                }, function () { root.setTimeout(next, 1000); });
            }
            next();
        }
    };

    // --- navigator.requestMIDIAccess (navigator_web_midi.cc) --------------------
    function requestMIDIAccess(options) {
        if (!(this instanceof Navigator)) {
            return Promise.reject(new TypeError("Illegal invocation"));
        }
        if (options !== undefined && options !== null && typeof options !== 'object' && typeof options !== 'function') {
            return Promise.reject(new TypeError("Failed to execute 'requestMIDIAccess' on 'Navigator': The provided value is not of type 'MIDIOptions'."));
        }
        // MIDIOptions, read as WebIDL reads a dictionary: members in order.
        // `software` asks for software synthesizers; macOS has none that
        // appear as MIDI ports, so it is read and changes nothing.
        var software = options ? !!options.software : false;
        var sysex = options ? !!options.sysex : false;
        void software;
        return call('request', { sysex: sysex }).then(function () {
            return hub.ports();
        }, function (err) {
            throw domException(err.name || 'NotAllowedError', err.message || 'Permission to use Web MIDI API was not granted.');
        }).then(function (list) {
            var access = newAccess(sysex, list);
            accesses.push(access);
            hub.poll();
            return access;
        }, function (err) {
            if (err instanceof DOMException) throw err;
            if (err && err.name === 'InvalidStateError') throw domException('InvalidStateError', 'Platform dependent initialization failed.');
            throw domException('AbortError', 'The MIDI system failed to start.');
        });
    }
    Object.defineProperty(requestMIDIAccess, 'length', { value: 0 });
    Object.defineProperty(Navigator.prototype, 'requestMIDIAccess', {
        value: requestMIDIAccess, writable: true, enumerable: true, configurable: true
    });

    // --- the Permissions API (spec 4.1) -------------------------------------------
    // navigator.permissions.query({name: "midi", sysex}), as Chrome answers
    // it.  Safari's Permissions API rejects names it does not know, so "midi"
    // is answered here and anything else goes to Safari.  The status is a
    // real EventTarget with PermissionStatus.prototype, so instanceof and
    // addEventListener work; it fires "change" when the decision changes.
    // Held weakly: a page that queries often must not keep every status it
    // was ever given.
    var statuses = [];
    function liveStatuses() {
        statuses = statuses.filter(function (r) { return r.deref() !== undefined; });
        return statuses.map(function (r) { return r.deref(); });
    }
    function permissionStatus(sysex, state) {
        var st = new EventTarget();
        Object.setPrototypeOf(st, root.PermissionStatus.prototype);
        hidden(st, { __state: state, __sysex: sysex, __onchange: null });
        Object.defineProperties(st, {
            state: { get: function () { return st.__state; }, enumerable: true, configurable: true },
            name: { value: 'midi', enumerable: true, configurable: true },
            onchange: {
                get: function () { return st.__onchange; },
                set: function (f) {
                    if (st.__onchange) st.removeEventListener('change', st.__onchange);
                    st.__onchange = typeof f === 'function' ? f : null;
                    if (st.__onchange) st.addEventListener('change', st.__onchange);
                },
                enumerable: true, configurable: true
            }
        });
        statuses.push(new WeakRef(st));
        return st;
    }
    listeners.set('permissionchange', function () {
        liveStatuses().forEach(function (st) {
            call('permission', { sysex: st.__sysex }).then(function (state) {
                if (state !== st.__state) { st.__state = state; st.dispatchEvent(new Event('change')); }
            }, function () {});
        });
    });
    if (root.Permissions && root.Permissions.prototype.query) {
        var safariQuery = root.Permissions.prototype.query;
        var query = function query(descriptor) {
            if (descriptor && typeof descriptor === 'object' && descriptor.name === 'midi') {
                var sysex = !!descriptor.sysex;
                return call('permission', { sysex: sysex }).then(function (state) {
                    return permissionStatus(sysex, state);
                }, function () { return permissionStatus(sysex, 'denied'); });
            }
            return safariQuery.apply(this, arguments);
        };
        Object.defineProperty(query, 'length', { value: 1 });
        Object.defineProperty(root.Permissions.prototype, 'query', {
            value: query, writable: true, enumerable: true, configurable: true
        });
    }

    [['MIDIAccess', MIDIAccess], ['MIDIPort', MIDIPort], ['MIDIInput', MIDIInput], ['MIDIOutput', MIDIOutput],
     ['MIDIInputMap', MIDIInputMap], ['MIDIOutputMap', MIDIOutputMap],
     ['MIDIMessageEvent', MIDIMessageEvent], ['MIDIConnectionEvent', MIDIConnectionEvent]
    ].forEach(function (c) {
        Object.defineProperty(root, c[0], { value: c[1], writable: true, configurable: true, enumerable: false });
    });
})();
