# Lua VM inside the game exe

Build 40408. Confirmed 2026-10-10 by string search and disassembly (pefile + capstone) of the exe.

## Version

**Lua 5.2.2, statically linked**, stock PUC-Rio layout. Evidence: the `$LuaVersion: Lua 5.2.2  Copyright (C)
1994-2013 Lua.org, PUC-Rio` ident string in `.rdata`; 5.2-only messages (`loop in gettable`, `_ENV`,
`attempt to yield across a C-call boundary`). The debug library is linked (`sethook`, `gethook`,
`external hook`), so `lua_sethook` / `lua_getinfo` exist in the binary. Not LuaJIT.

## Functions

| RVA | Function | How identified |
|---|---|---|
| `0x2fc8f40` | `luaV_execute(lua_State *L)` — interpreter loop | references `'for' initial value must be a number` etc.; body matches the 5.2 fetch/hook check |
| `0x2fbf238` (chunk) | `auxgetinfo` / `funcinfo` part of `lua_getinfo` | references `=[C]`; fills `lua_Debug` |
| `0x2fab090` | `lua::CheckedCall` (engine wrapper, `lua_call.cpp`) | assert strings |
| `0x2fd4c10` | `db_sethook` area (`external hook`) | string |

`luaV_execute` prologue: `mov r13,[rcx+20h]` (ci), **`mov rbp,rcx` — `L` lives in `rbp` for the whole
function.** Signature used by the profiler (unique in build 40408):

```
40 53 55 56 57 41 54 41 55 41 56 41 57 48 83 EC 78 4C 8B 69 20 48 8B E9 C5 F8 29 74 24 60
C5 FB 10 35 ?? ?? ?? ?? C5 F8 29 7C 24 50
```

## Struct offsets (x64), each read off the game's own code

| Field | Offset | Seen in |
|---|---|---|
| `lua_State.tt` (8 = thread) | `+0x08` | CommonHeader |
| `lua_State.ci` | `+0x20` | `luaV_execute`: `mov r13,[rcx+20h]` |
| `lua_State.hookmask` / `hookcount` | `+0x48` / `+0x50` | `luaV_execute` hook check |
| `CallInfo.func` | `+0x00` | `mov rax,[r13]` |
| `CallInfo.previous` | `+0x10` | stock 5.2.2 layout (func, top, previous, next) |
| `CallInfo.callstatus` (bit 0 = `CIST_LUA`) | `+0x22` | getinfo: `test byte [r14+22h],1` |
| `CallInfo.u.l.base` / `savedpc` | `+0x30` / `+0x38` | `luaV_execute`, getinfo `currentline` |
| closure type byte (6 = Lua, `0x26` = C) | `+0x08` | getinfo: `cmp byte [r15+8],26h` |
| `LClosure.p` | `+0x18` | `mov r8,[r15+18h]` |
| `Proto.k` / `code` / `lineinfo` | `+0x10` / `+0x18` / `+0x28` | `luaV_execute`, `currentline` |
| `Proto.source` (`TString*`) | `+0x48` | `mov rdx,[r8+48h]` |
| `Proto.sizelineinfo` | `+0x5C` | stock layout |
| `Proto.linedefined` / `lastlinedefined` | `+0x68` / `+0x6C` | `mov eax,[r8+68h]` / `[r8+6Ch]` |
| `TString.len`, characters | `+0x10`, `+0x18` | `add rdx,18h` |

Current line of a Lua frame: `lineinfo[(savedpc - code) / 4 - 1]`.

## Use

`native/src/profiler.cpp` reads the Lua call stack of a sampled thread with these offsets: when
`luaV_execute` is on the native stack it takes `rbp` from that frame as `L`, validates it, and walks
`L->ci` back through `previous`. Read-only; nothing is hooked or written.

## Threads that run Lua (profile of 2026-10-10)

Main Thread (GUI/game-script callbacks via `lua::CheckedCall`), and the Sim Pool threads (game-script
`update`), also Main Pool workers to a small degree.
