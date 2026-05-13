# LookinServer Multi-Client Support — Plan

Status: in progress

## Background

`LKS_ConnectionManager` currently allows exactly one connected client at a
time. When a second client (e.g. the CLI) connects to a target app while
the GUI is already attached, the GUI's channel is `[previousChannel cancel]`'d
and the new client takes over. CLI users see "No inspectable apps found"
when the GUI is open because the listening channel transitions to
`connected` and stops accepting peers.

We want any number of clients (GUI + 1+ CLI sessions) to attach to the
same target app simultaneously, isolated from each other, with no client
needing to know that anyone else is connected.

## Why this is feasible

- **peertalk already supports it.** `Lookin_PTChannel listenOnPort:` keeps
  the listening fd open and produces a *new* connected `Lookin_PTChannel`
  per `accept()` (see `Lookin_PTChannel.m:382-454`). The single-client
  restriction lives entirely in the LookinServer business layer.
- **Protocol is request/response with explicit tags.** Every frame carries
  `(type, tag, payload)`; routing responses back to the originating client
  only needs the channel ref, no protocol changes.
- **No shared mutable state in the request path that breaks.** Most
  reflection happens on the main queue; the only per-handler state today
  (`activeDetailHandlers`) is naturally per-channel once we instantiate a
  handler per connection.

## Non-goals

- No cross-client session sync. If client A modifies a view's property,
  client B will see the new value the next time it pulls — not pushed.
- No auth / permission. This is loopback localhost debugging; we trust
  every connection on the host as before.
- No concurrency throttling. If two clients hit `makeViewDebugData` at
  the same time, both requests just dispatch to main as before.
- No GUI client changes. The GUI sees a strict superset of its old
  behaviour.
- No CLI client changes. The CLI's connect/list/RPC code is already
  agnostic to whether it's the only client.

## Design

### Today

```
LKS_ConnectionManager (singleton)
  peerChannel_  ─→ Lookin_PTChannel  (single, listening OR connected)
  requestHandler ─→ LKS_RequestHandler  (single instance)
```

`peerChannel_` is mutated in three places:
- `_tryToListenOnPortFrom:to:current:` after a successful `bind+listen`
  (`LKS_ConnectionManager.m:160`)
- `didAcceptConnection:` (line 226) — replaces the listening channel with
  the new connected channel and `cancel`s the previous one
- `didEndWithError:` (line 240) — clears it and re-runs port search

### After

```
LKS_ConnectionManager (singleton)
  listeningChannel_  ─→ Lookin_PTChannel  (always listening, never connected)
  peerChannels_      ─→ NSHashTable<Lookin_PTChannel *>  (weak refs)
                          ├─ channel A  + channel.userInfo = handler A
                          ├─ channel B  + channel.userInfo = handler B
                          └─ channel C  + channel.userInfo = handler C
```

- `LKS_RequestHandler` becomes per-connection.
- Handler holds `__weak Lookin_PTChannel *channel_` and sends responses
  directly via `[channel_ sendFrameOfType:tag:withPayload:]` instead of
  going through `LKS_ConnectionManager respond:`.

### Decisions

| Question | Choice | Rationale |
|---|---|---|
| Response routing | Handler sends directly on its bound channel | Removes the need for a `respond:onChannel:` facade and matches the per-instance handler model |
| Handler instantiation | One handler per connection | State (`activeDetailHandlers`, future per-session caches) is naturally isolated; instance cost is negligible |
| Compatibility flag | None | Multi-client is a strict superset; an `LKS_SINGLE_CLIENT=1` escape hatch would expand the test matrix forever and never be removed |
| `pushData:` strategy | Broadcast to all channels (v1) | The only existing push (`LookinPush_BringForwardScreenshotTask`) is a UI hint that's safe to fan out; if a future push needs a target, route then |
| `validRequestTypes` move to `static` | **Skip in v1** | Pure micro-optimisation; orthogonal to the multi-client work and not on the critical path. Defer to a later cleanup |

### Lifecycle

#### Startup

1. `init` → calls `searchPortToListenIfNotListening`
2. `searchPortToListenIfNotListening` walks `LookinMacIPv4PortNumberStart..End`
   trying `bind+listen` until one succeeds
3. The successful channel is stored as `listeningChannel_`. The dispatch
   source on that fd will fire on every incoming connection forever, so
   no need to re-listen after each accept.

#### New connection

1. peertalk's `acceptIncomingConnection:` creates a fresh connected
   `Lookin_PTChannel` and invokes our `didAcceptConnection:`
2. We **do not** touch any existing channel
3. We add the new channel to `peerChannels_`
4. We create a `LKS_RequestHandler` bound to this channel and stash it in
   `channel.userInfo` (peertalk reserves `userInfo` for app use)

#### Frame in / out

1. `shouldAcceptFrameOfType:` retrieves the per-channel handler via
   `channel.userInfo` and asks it to validate the request type
2. `didReceiveFrameOfType:` dispatches to that handler's
   `handleRequestType:tag:object:`
3. The handler responds by calling
   `[self->channel_ sendFrameOfType:tag:withPayload:]` directly

#### Disconnect

`didEndWithError:` distinguishes two cases:

- **The closing channel is `listeningChannel_`** — listening fd died (rare;
  e.g. process binding edge cases). Run `searchPortToListenIfNotListening`
  to find a new port.
- **The closing channel is in `peerChannels_`** — a client went away.
  Remove from the hash table. Cancel any in-flight detail handlers owned
  by that handler (this happens naturally because the handler is GC'd
  when nothing else holds it).

`searchPortToListenIfNoConnection` semantics shift: it used to mean "if
there's no client, find a port"; now it means "if there's no listener,
find a port". The new name reflects that.

### Concurrency safety review

| Shared state | Today | After multi-client |
|---|---|---|
| `LKS_ObjectRegistry` (oid table) | Singleton, must already be thread-safe (verify) | Independent oid use across clients — no contention |
| `LKS_TraceManager`, `LKS_CustomAttrSetterManager` | Singletons; reflection serialises on main queue | Same: requests pile up on main but stay correct |
| `NSView` / `UIView` properties | Read on main thread | Same |
| `LookinAppInfo currentInfoWithScreenshot:` | Main thread + CGContext | Same; concurrent calls just queue. Future opt: short-lived screenshot cache |
| `activeDetailHandlers` | NSMutableSet on the singleton handler | Per-channel handler owns its own set — natural isolation |

No new mutexes required. Existing main-queue serialisation is what
keeps view reflection correct, and that doesn't change.

### Protocol compatibility

- TCP and frame format identical
- Tag/request-type semantics identical
- Single-client GUIs see no behavioural change
- An older client that cached "I'm the only one" assumptions doesn't
  exist — the wire protocol never advertised exclusivity

## Files touched

| File | Change |
|---|---|
| `Sources/LookinServer/Server/Connection/LKS_ConnectionManager.h` | Replace `peerChannel_` with `listeningChannel_` + `peerChannels_`. Drop `respond:requestType:tag:`. |
| `Sources/LookinServer/Server/Connection/LKS_ConnectionManager.m` | Rewrite `didAcceptConnection:`, `didEndWithError:`, `shouldAcceptFrameOfType:`, `didReceiveFrameOfType:`. Rename + retarget `searchPortToListenIfNoConnection`. Make `pushData:` broadcast. Drop `respond:` (handlers send directly). |
| `Sources/LookinServer/Server/Connection/LKS_RequestHandler.h` | Add `- (instancetype)initWithChannel:(Lookin_PTChannel *)channel;` |
| `Sources/LookinServer/Server/Connection/LKS_RequestHandler.m` | Hold `__weak Lookin_PTChannel *channel_`. Replace `[manager respond:...]` calls with direct `[channel_ sendFrameOfType:...]`. |
| `Sources/LookinServer/Server/Connection/RequestHandler/LKS_HierarchyDetailsHandler.m` | If it sends responses through the manager, retarget to the bound channel — but it currently uses the singleton path, which we are removing. Verify and adapt. |
| `Sources/LookinServer/Server/Connection/RequestHandler/LKS_*Handler.m` | Same audit. |
| `LookInside/DerivedSource/...` | Refresh via `Scripts/sync-derived-source.sh` |

CLI (`Sources/LookInsideCLI/`) and macOS app (`LookInside/`) source: no
changes expected.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Existing reflection assumes a single response sink and breaks under per-channel routing | Low | Audit every `[LKS_ConnectionManager sharedInstance] respond:`/`pushData:` site during edit |
| `pushData:` broadcast triggers UI surprise on idle clients | Low | Only one push type exists today; behaviour is a hint, not a command |
| `LKS_HierarchyDetailsHandler`'s pagination stream gets cancelled across clients | Was a real risk under shared handler; eliminated by per-channel handler | — |
| `listeningChannel_` dies but connected channels survive — no new clients can attach | Low | `didEndWithError:` distinguishes the two cases and re-listens |
| Heavy concurrent screenshot/reflection hangs main queue | Medium | Same as today for one client doing many requests; deferred to v2 cache work |

## Validation

Per `AGENTS.md` checklist plus multi-client smoke:

1. `bash Scripts/sync-derived-source.sh`
2. `swift build`
3. `swift build -c debug --product lookinside`
4. `xcodebuild -skipMacroValidation -project LookInside.xcodeproj -scheme LookInside -configuration Debug -derivedDataPath /tmp/LookInsideDerivedData CODE_SIGNING_ALLOWED=NO build`
5. Single-client regression — open GUI, run hierarchy / properties /
   measurements / view debug as before; behaviour unchanged.
6. Two-client smoke — open GUI on a target app; in another terminal run
   `lookinside list` and `lookinside hierarchy --target ...`; both work
   without disconnecting the GUI.
7. Multi-CLI smoke — two parallel CLI processes against the same target,
   each running `swiftui-debug --tree` against different OIDs; outputs
   independent and correct.
8. Disconnect resilience — quit the GUI; CLI continues to work. Quit the
   CLI; GUI continues to work. Restart either, reconnect succeeds.

## Out of scope (future work)

- `pushData:` per-channel routing. Add when a push type needs targeting.
- `validRequestTypes` static cleanup. Pure refactor, not on critical path.
- Screenshot/reflection result cache to avoid recomputing for concurrent
  clients hitting the same OID within a short window.
- An XPC-bridged "broker" mode (Plan A from earlier discussion) that
  allows multi-client without re-integrating LookinServer into target
  apps. Out of scope for this branch but possible follow-up.

## Estimated diff

~120 lines net across the LookinServer files listed above. Zero lines
in CLI or macOS app sources.
