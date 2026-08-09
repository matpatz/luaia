# luaia

Luau minifier written in Luau. Parses source code into an AST, optimizes it, and generates compact output.

## Install

### With Rokit

luaia is published as a [Rokit](https://github.com/rojo-rbx/rokit) tool. Add it to your project's `rokit.toml`:

```toml
[tools]
luaia = "matpatz/luaia@0.4.0"
```

Then run `rokit install` and use it as a standalone `luaia` command:

```
luaia <file>
luaia <file> -o <out>
```

To update when a new version is released, bump the version in `rokit.toml` (or run `rokit update matpatz/luaia`) and then run `rokit install`. Note that `rokit update` only changes the pinned version in the manifest — `rokit install` is what actually downloads and links the new binary.

### Standalone binary

Prebuilt binaries for every platform are attached to each [release](https://github.com/matpatz/luaia/releases) — no Lune or Rokit needed. Download the archive for your system, unzip it, and run.

**Windows**

1. Grab `luaia-0.4.0-windows-x86_64.zip` (or `luaia-0.4.0-windows-aarch64.zip` on ARM64).
2. Unzip it — you'll get `luaia.exe`.
3. Run it from a terminal:

```
luaia.exe <file>
luaia.exe <file> -o <out>
```

Drop `luaia.exe` into a folder that's on your `PATH` (e.g. `C:\Windows`) and you can call `luaia` from anywhere.

**macOS / Linux**

Download the matching `macos-x86_64`, `macos-aarch64`, `linux-x86_64`, or `linux-aarch64` archive, extract the `luaia` binary, and make it executable:

```
chmod +x luaia
./luaia <file>
```

The standalone binary takes the exact same flags as running from source — call it directly instead of `lune run bin/cli.lua`.

### From source

Requires [lune](https://github.com/lune-org/lune) 0.10.x to run. luaia is pure Luau — there is no compile step; it runs directly from source.

```
git clone https://github.com/matpatz/luaia.git
cd luaia
lune run bin/cli.lua <file>
```

The repo ships a `rokit.toml` that pins lune 0.10.5. If you use [rokit](https://github.com/rojo-rbx/rokit), it will install the right version for you:

```
rokit install
```

## Usage

### CLI

Using the standalone binary (see [Install](#install)):

```
luaia <file>                  Minify a file (stdout)
luaia <file> -o <out>         Write output to file
luaia <file> -r               Minify and run output
luaia <file> -o <out> -r      Write to file and run it
luaia -s <source>             Minify raw source
luaia --stdin                 Read from stdin
luaia --pack-locals -s <src>  Pack locals into tables
```

On Windows the binary is `luaia.exe`. Running from source is identical — just replace `luaia` with `lune run bin/cli.lua`.

#### Options

| Flag | Description |
|------|-------------|
| `-s <source>` | Minify raw source instead of a file |
| `-o <file>` | Write minified output to file |
| `-t` | Logs time of minification |
| `-r` | Run the minified output with lune |
| `--no-fold` | Disable constant folding |
| `--no-rename` | Disable variable renaming |
| `--no-localize` | Disable global function localization |
| `--no-bools` | Disable boolean literal localization |
| `--no-strings` | Disable repeated string localization |
| `--no-dce` | Disable dead code elimination |
| `--table-keys` | Enable table field renaming (off by default) |
| `--table-fold` | Enable table constant folding (off by default) |
| `--pack-locals` | Store locals in tables to bypass Luau's local limit |
| `--version` | Show version |
| `--help` | Show help |

#### Examples

```sh
# Minify to stdout
luaia script.luau

# Minify raw source
luaia -s "print('hello')"

# Write to file
luaia script.luau -o min.luau

# Minify and run
luaia script.luau -r

# Pipe from stdin
cat script.luau | luaia --stdin
```

> From source, replace `luaia` with `lune run bin/cli.lua`.
> `-r` runs the minified output through Lune, so it needs [lune](https://github.com/lune-org/lune) installed.

### Library

```lua
local luaia = require("@luaia")

local result, errors = luaia.Minify(source, {
    Rules = {
        MinifyVariables = true,  -- rename local variables (default: true)
        ConstantFold = true,     -- fold constants (default: true)
        LocalizeGlobals = true,  -- hoist global functions into locals (default: true)
        LocalizeBooleans = true, -- hoist true/false literals into locals (default: true)
        LocalizeStrings = true, -- hoist repeated string literals into locals (default: true)
        DeadCodeElimination = true, -- remove dead code (default: true)
        RenameTableKeys = false, -- rename table fields (default: false)
        TableConstantFolding = false, -- fold immutable table reads (default: false)
    },
})

if result then
    print(result)
else
    for _, err in errors do
        warn(err)
    end
end
```

### PackVariables

`PackVariables` is a separate lowering pass for scripts that exceed Luau's
200-local-per-function limit. It replaces ordinary locals with fields in a
private table for each function, preserving captured locals and parameters.
Loop bodies get a fresh table per iteration so closures preserve their
per-iteration locals. Loop control variables remain generated locals because
Lua's loop and closure semantics require a distinct control variable.

```lua
local result, errors = luaia.PackVariables(source)
```

Use `--pack-locals` from the CLI. This mode is intentionally separate from
`Minify`; it performs only the variable lowering pass.

## Rules

Rules are individually toggleable optimizations. Most are on by default; pass `Rules = { <Rule> = false }` to disable a specific one, or `--no-<rule>` from the CLI. `RenameTableKeys` and `TableConstantFolding` are the exceptions — both are **off** by default and must be enabled with `Rules = { RenameTableKeys = true }` / `--table-keys`, or `Rules = { TableConstantFolding = true }` / `--table-fold`.

| Rule | CLI flag | Description |
|------|----------|-------------|
| `MinifyVariables` | `--no-rename` | Rename local variables to short names |
| `ConstantFold` | `--no-fold` | Fold constant expressions |
| `RemoveRedundantParens` | | Remove redundant parentheses |
| `LocalizeGlobals` | `--no-localize` | Hoist global function references into local variables |
| `LocalizeBooleans` | `--no-bools` | Replace repeated `true`/`false` literals with aliased locals |
| `LocalizeStrings` | `--no-strings` | Replace string literals repeated more than three times with aliased locals |
| `DeadCodeElimination` | `--no-dce` | Fold constant conditions, drop dead branches, and remove unused locals |
| `RenameTableKeys` | `--table-keys` | Rename table fields to short names (off by default) |
| `TableConstantFolding` | `--table-fold` | Fold reads of immutable table literals (off by default) |

### LocalizeGlobals

Caches references to global functions in top-of-file locals so repeated lookups are skipped. Any global reference is hoisted automatically — plain globals (`print`, `pairs`, `setmetatable`, …) and module members (`math.floor`, `string.upper`, `table.insert`, …) — even when used once.

```lua
-- Input
print(math.floor(3.7))
print(math.floor(5.2))
print(string.upper("hi"))

-- Output (abbreviated)
local a=print;local b=math.floor;local c=string.upper;a(b(3.7));a(b(5.2));a(c("hi"));
```

A global is left inline if it is ever reassigned in the file (e.g. `math.floor = ...` or `function math.floor() ... end`), so the alias never captures a stale value.

### LocalizeBooleans

Replaces repeated `true`/`false` literals with aliases declared once at the top of the file. Only applied when the number of occurrences outweighs the cost of the declaration, so scripts with just a couple of literals are left untouched.

```lua
-- Input
local flags = { true, false, true, false, true, false, true, false }

-- Output (abbreviated)
local a,b=true,false;local flags={a,b,a,b,a,b,a,b};
```

### DeadCodeElimination

Tracks which locals are never used and folds branches that can be proven dead at compile time. Local values are only treated as constant when they are never assigned after initialization, so captured variables and values changed by function calls are left alone.

```lua
-- Input
local a = false
if a then
    print("a is true")
else
    print("a is false")
end

-- Output
local a=print;a("a is false");
```

### TableConstantFolding

Extends dead code elimination with constant propagation through table literals. When a local holds a table literal that can never be mutated or observed from code luaia can't rewrite, reads like `b["a"]` fold like scalar constants — so conditions that are always true are unwrapped and always-false branches are dropped. This is an aggressive rule, so it is **off by default** (enable with `--table-fold` or `Rules = { TableConstantFolding = true }`). It only takes effect when `DeadCodeElimination` is also enabled.

```lua
-- Input
local a = true
local b = {
    ["a"] = true
}

if a and b["a"] == true then
    print("yay")
end

-- Output
print("yay")
```

A table is left untouched — nothing is folded through it — whenever its contents could change or leak, so behavior never changes:

- the local is reassigned or a field is written (`b.a = x`, `b.a += x`) anywhere in the file, including inside functions,
- the table is returned, stored into a global or environment field (`_G.a = b`, `shared.a = b`, `getfenv().a = b`, ...),
- the table (or one of its sub-tables) is aliased to another local,
- the table is embedded in another table, passed to a call, used as a method receiver, or used as a table key.

Only constant keys are folded — `b[someLocal]` and fields with side-effectful or otherwise non-constant values are left alone, and side-effectful initializers are preserved.

### RenameTableKeys

Renames the fields of table literals assigned to locals — including nested tables — to short generated names, and rewrites every access accordingly. This is an obfuscation rule, so it is **off by default** (enable with `--table-keys` or `Rules = { RenameTableKeys = true }`).

```lua
-- Input
local a = {
    sub1 = { x = 32 },
    m = true
}
if a.m then
    print(a.sub1.x + 32)
end

-- Output (abbreviated)
local a = {
    b = { c = 32 },
    d = true
}
if a.d then
    print(a.b.c + 32)
end
```

A table is left untouched whenever its fields could be observed from code luaia can't rewrite, so renaming can't break anything:

- the local is reassigned after initialization,
- the table is returned (`return a` in a module),
- the table is stored into a global or environment field (`_G.a = a`, `shared.a = a`, `getfenv().a = a`, `getgenv().a = a`, or any `x.y = a`),
- the table (or one of its sub-tables) is aliased to another local,
- the table is embedded in another table, passed to a call, used as a method receiver, or used as a table key,
- the table (or one of its sub-tables) is read with a dynamic index (`a[k]`, `a.sub[k]`) — the key can't be rewritten, so it must keep its original name. Its own keys stay untouched, but the tables stored inside it are still renamed via a shared "family" map when they all use the same field names (the classic `registry[id]` dispatch pattern), so fields like `registry[id].Code` rename safely.

Side-effectful initializers are preserved (e.g. `local x = print("hi")`), and a branch is only removed when its condition is a known constant, so behavior never changes.

## Before/After

```lua
-- Input
local longVariableName = 10
local anotherLongName = 20
print(longVariableName + anotherLongName)

function myFunc(param1, param2)
    local result = param1 + param2
    return result
end
```

```lua
-- Output
local a=10;local b=20;print(a+b);myFunc=function(c,d)local e=c+d;return e;end;
```

## Benchmarks

Input: 17.6kb
--

Runs | Total | Avg/Run
-----|-------|--------
   1x |   9ms |    9ms
  10x |  90ms |    9ms
  50x | 398ms |    8ms
 100x | 808ms |    8ms

Measure yourself with `lune run bin/cli.lua test/input.lua -t`.


## Project Structure

```
src/
  init.luau          Public API
  Parser.luau        Wraps LuauParser with storeCstData = false
  Transformer.luau   AST optimizations (folding, renaming)
  VariablePacker.luau Lowers locals into per-function tables
  Generator.luau     AST to minified string
  utils.luau         Shared helpers
  LuauParser/        Embedded parser (by vantoanvh)
bin/
  cli.lua            CLI entry point
tests/
  run.luau           Test runner
  suites/luaia.luau  Test cases
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for style guidelines.

## License

GPLv3 — see [LICENSE](LICENSE).
