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
    MinifyVariables = true,  -- rename local variables (default: true)
    ConstantFold = true,     -- fold constants (default: true)
    Rules = {
        LocalizeGlobals = true, -- hoist global functions into locals (default: true)
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
| `LocalizeGlobals` | `--no-localize` | Hoist global function references into local variables |

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
