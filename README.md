# luaia

Luau minifier written in Luau. Parses source code into an AST, optimizes it, and generates compact output.

## Install

### With Rokit

luaia is published as a [Rokit](https://github.com/rojo-rbx/rokit) tool. Add it to your project's `rokit.toml`:

```toml
[tools]
luaia = "matpatz/luaia@0.1.1"
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

1. Grab `luaia-0.1.1-windows-x86_64.zip` (or `luaia-0.1.1-windows-aarch64.zip` on ARM64).
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
luaia --stdin                 Read from stdin
```

On Windows the binary is `luaia.exe`. Running from source is identical — just replace `luaia` with `lune run bin/cli.lua`.

#### Options

| Flag | Description |
|------|-------------|
| `-o <file>` | Write minified output to file |
| `-t` | Logs time of minification |
| `-r` | Run the minified output with lune |
| `--no-fold` | Disable constant folding |
| `--no-rename` | Disable variable renaming |
| `--no-localize` | Disable global function localization |
| `--no-bools` | Disable boolean literal localization |
| `--no-dce` | Disable dead code elimination |
| `--version` | Show version |
| `--help` | Show help |

#### Examples

```sh
# Minify to stdout
luaia script.luau

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
        DeadCodeElimination = true, -- remove dead code (default: true)
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

## Rules

Rules are individually toggleable optimizations. Enable them all by default; pass `Rules = { <Rule> = false }` to disable a specific one, or `--no-<rule>` from the CLI.

| Rule | CLI flag | Description |
|------|----------|-------------|
| `MinifyVariables` | `--no-rename` | Rename local variables to short names |
| `ConstantFold` | `--no-fold` | Fold constant expressions |
| `RemoveRedundantParens` | | Remove redundant parentheses |
| `LocalizeGlobals` | `--no-localize` | Hoist global function references into local variables |
| `LocalizeBooleans` | `--no-bools` | Replace repeated `true`/`false` literals with aliased locals |
| `DeadCodeElimination` | `--no-dce` | Fold constant conditions, drop dead branches, and remove unused locals |

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
