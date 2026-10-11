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

## Lua C API functions (for the native-to-script bridge)

Build 40408, found 2026-10-11 by disassembly. Starting point: `luaopen_base` at `+0x2fcdc00` (the only
function referencing both `_G` and `_VERSION`), whose calls are, in order, `lua_rawgeti(L, REGISTRYINDEX, 2)`
(push the globals table), `lua_setfield(L, -2, "_G")`, `luaL_setfuncs`, `lua_pushlstring("Lua 5.2", 7)`,
`lua_setfield`. `luaL_setfuncs` (`+0x2fb4290`) then gives `lua_pushvalue`, `lua_pushcclosure`, `lua_settop`.
The API functions sit together in alphabetical order by name; the rest were identified from their bodies
(leaf functions are unmistakable: they write a value and a type tag at `L->top` and add 16).

| RVA | Function | Identified by |
|---|---|---|
| `0x2fbd510` | `index2addr` (internal helper) | called first by every indexed API function |
| `0x2fbd650` | `lua_checkstack` | called from `luaL_setfuncs`' inlined `luaL_checkstack` |
| `0x2fbd880` | `lua_createtable(L, narr, nrec)` | GC check, then table creation with both sizes |
| `0x2fbdc00` | `lua_getglobal(L, name)` | reads registry slot 2, then a table get |
| `0x2fbdce0` | `lua_gettable` | |
| `0x2fbdd10` | `lua_gettop` | leaf: `(top - (ci->func + 1)) >> 4` |
| `0x2fbe0c0` | `lua_pcallk` | |
| `0x2fbe1d0` | `lua_pushboolean` | leaf: tag 1 |
| `0x2fbe1f0` | `lua_pushcclosure(L, fn, n)` | called in the `luaL_setfuncs` loop |
| `0x2fbe300` | `lua_pushinteger` | leaf: int to double, tag 3 |
| `0x2fbe320` | `lua_pushlightuserdata` | leaf: tag 2 |
| `0x2fbe340` | `lua_pushlstring(L, s, len)` | called by `luaopen_base` with ("Lua 5.2", 7) |
| `0x2fbe3c0` | `lua_pushnumber` | leaf: tag 3 from xmm1 |
| `0x2fbe3e0` | `lua_pushstring` | nil for a null pointer |
| `0x2fbe4b0` | `lua_pushvalue` | |
| `0x2fbe590` | `lua_rawget` | |
| `0x2fbe5d0` | `lua_rawgeti` | called by `luaopen_base` with the registry index |
| `0x2fbe660` | `lua_rawlen` | |
| `0x2fbe8f0` | `lua_setfield(L, idx, k)` | called by `luaopen_base` with "_G" |
| `0x2fbe960` | `lua_setglobal(L, name)` | mirror of `lua_getglobal` |
| `0x2fbeaf0` | `lua_settop` | tail-called by `luaL_setfuncs` (leaf, no unwind entry) |
| `0x2fbecb0` | `lua_toboolean` | false for nil and for boolean false |
| `0x2fbece0` | `lua_tointegerx` | |
| `0x2fbed30` | `lua_tolstring(L, idx, len*)` | to be confirmed against a caller before use |
| `0x2fbee20` | `lua_touserdata` / `lua_topointer` | to be confirmed |
| `0x2fbef90` | `lua_type` | returns the tag's low 4 bits, -1 for "none" |
| `0x2fbefc0` | `lua_typename` | table lookup |
| `0x2fbf0c0` | `lua_version` | |
| `0x2fb34a0` | `luaL_error` | called with format strings by `luaL_setfuncs`' version check |
| `0x2fb4290` | `luaL_setfuncs` | |

Not present as separate functions (inlined by the compiler): `lua_pushnil`, `lua_getfield`.
`LUA_REGISTRYINDEX` = `-1001000` (`0xFFF0B9D8`); the globals table is registry slot 2.

Plan for the bridge: hook `lua::CheckedCall` (`+0x2fab090`), which runs on the state's own thread at a
point where the Lua stack is balanced; the first time a state is seen, build one table of C functions and
store it as a global. Every address above needs its own signature before it is used.

## Functions for a Lua state of our own (the worker)

Build 40408, found 2026-10-12 by following references from strings and tables (script kept outside the
repository; the method is what matters):

| RVA | Function | How it was found |
|---|---|---|
| `0x2fc13d0` | `lua_newstate(alloc, ud)` | `f_luaopen` (`0x2fc1150`) is the only function referring to "not enough memory" from Lua's code; `lua_newstate` takes its address to run it protected. Its body begins by calling the allocator with (ud, NULL, 8, 0x2c0): a thread object of `sizeof(LG)` |
| `0x2fbdf70` | `lua_load(L, reader, data, chunkname, mode)` | `f_parser` (`0x2fc2350`) refers to "attempt to load a %s chunk (mode is '%s')"; `luaD_protectedparser` (`0x2fc2bd0`) takes `f_parser`'s address; `lua_load` is its only caller. It also falls back to the chunk name "?" |
| `0x2fd2230` | `luaopen_string` | takes the address of the function list holding "gmatch" and "gsub" |
| `0x2fceaf0` | `luaopen_table` | takes the address of the function list holding "concat" and "unpack" |
| `0x2fd3fe0` | `luaopen_math` | takes the address of the function list holding "frexp" and "atan2" |

The same method, applied to "ipairs" and "tostring", lands on `luaopen_base` at the address already known,
which is the check that it works.

Not found, and why it does not matter:
- `luaL_newstate`: the game does not use it (there is no "PANIC: unprotected error" string). It makes its
  states with `lua_newstate` and its own allocator; the worker passes an allocator of its own.
- `lua_close`: has nothing distinctive to find it by. The worker keeps one state for the life of the process
  and leaves a replaced one behind.

`luaopen_table` cannot be told from `luaopen_coroutine` (`0x2fce170`) by its bytes: both make a table of six
functions and register a list. The DLL takes both matches and keeps the one whose list starts with "concat".
`tools/check_signatures.py` therefore reports that one pattern as matching twice; that is expected.

In this build `luaL_newlib` is `lua_createtable(L, 0, n)` followed by `luaL_setfuncs(L, list, 0)`, and a
library opener returns its table on the stack; the base library writes into the globals itself.
