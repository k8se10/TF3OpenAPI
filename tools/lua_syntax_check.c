/* Lua syntax check with the vendored Lua 5.4 (the game runs Lua 5.2; both reject what 5.1 lets through,
   such as "..." inside a function that is not itself vararg). Build (x64 Native Tools prompt, repo root):
     cl /nologo /O1 /I native\third_party\lua tools\lua_syntax_check.c native\third_party\lua\l*.c /Fe:lua_syntax_check.exe
   (leave out lua.c / luac.c if present). Run: lua_syntax_check <file.lua> ...  */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
int main(int argc, char** argv) {
    int bad = 0;
    lua_State* L = luaL_newstate();
    for (int i = 1; i < argc; ++i) {
        if (luaL_loadfile(L, argv[i]) != LUA_OK) { printf("%s\n", lua_tostring(L, -1)); ++bad; }
        lua_settop(L, 0);
    }
    lua_close(L);
    printf("%d file(s), %d with errors\n", argc - 1, bad);
    return bad ? 1 : 0;
}
