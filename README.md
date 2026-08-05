# luaia

Luau minifier written in Luau. Parses source code into an AST, optimizes it, and generates compact output.

## Install

Requires [lune](https://github.com/lune-org/lune) to run.

```
lune install luaia
```

Or clone and use directly:

```
git clone https://github.com/matpat/luaia.git
cd luaia
lune run bin/cli.lua <file>
```

## Usage

### CLI

```
luaia <file>           Minify a file (stdout)
luaia <file> -o <out>  Write output to file
luaia <file> -r        Minify and run output
luaia <file> -o <out> -r  Write to file and run it
luaia --stdin          Read from stdin
```

#### Options

| Flag | Description |
|------|-------------|
| `-o <file>` | Write minified output to file |
| `-r` | Run the minified output with lune |
| `--no-fold` | Disable constant folding |
| `--no-rename` | Disable variable renaming |
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

### Library

```lua
local luaia = require("@luaia")

local result, errors = luaia.Minify(source, {
    MinifyVariables = true,  -- rename local variables (default: true)
    ConstantFold = true,     -- fold constants (default: true)
})

if result then
    print(result)
else
    for _, err in errors do
        warn(err)
    end
end
```

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

Measured on a 606KB file (20K lines of real Luau code):
--
Input: 606.4kb

Runs | Total | Avg/Run
-----|-------|--------
   1x | 189ms | 189ms
  10x | 1.90s | 190ms
  50x | 9.23s | 185ms
 100x | 18.58s | 186ms
--

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
