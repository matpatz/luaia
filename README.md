# luaia

Luau minifier written in Luau. Parses source code into an AST, optimizes it, and generates compact output.

## Install

Requires [lune](https://github.com/lune-org/lune) 0.10.x to run. luaia is pure Luau — there is no compile step; it runs directly from source.

```
git clone https://github.com/matpat/luaia.git
cd luaia
lune run bin/cli.lua <file>
```

The repo ships a `rokit.toml` that pins lune 0.10.5. If you use [rokit](https://github.com/rojo-rbx/rokit), it will install the right version for you:

```
rokit install
```

## Usage

### CLI

```
lune run bin/cli.lua <file>                  Minify a file (stdout)
lune run bin/cli.lua <file> -o <out>         Write output to file
lune run bin/cli.lua <file> -r               Minify and run output
lune run bin/cli.lua <file> -o <out> -r      Write to file and run it
lune run bin/cli.lua --stdin                 Read from stdin
```

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
lune run bin/cli.lua script.luau

# Write to file
lune run bin/cli.lua script.luau -o min.luau

# Minify and run
lune run bin/cli.lua script.luau -r

# Pipe from stdin
cat script.luau | lune run bin/cli.lua --stdin
```

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
