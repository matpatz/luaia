-- A very large Lua test file for minifier testing
-- This file contains various Lua patterns and features

local function fibonacci(n)
    if n <= 1 then
        return n
    end
    return fibonacci(n - 1) + fibonacci(n - 2)
end

local function factorial(n)
    if n == 0 or n == 1 then
        return 1
    end
    return n * factorial(n - 1)
end

local function isPrime(num)
    if num < 2 then
        return false
    end
    if num == 2 then
        return true
    end
    if num % 2 == 0 then
        return false
    end
    for i = 3, math.sqrt(num), 2 do
        if num % i == 0 then
            return false
        end
    end
    return true
end

local function quickSort(arr, low, high)
    if low < high then
        local pi = partition(arr, low, high)
        quickSort(arr, low, pi - 1)
        quickSort(arr, pi + 1, high)
    end
    return arr
end

local function partition(arr, low, high)
    local pivot = arr[high]
    local i = low - 1
    for j = low, high - 1 do
        if arr[j] < pivot then
            i = i + 1
            arr[i], arr[j] = arr[j], arr[i]
        end
    end
    arr[i + 1], arr[high] = arr[high], arr[i + 1]
    return i + 1
end

local function binarySearch(arr, target)
    local left = 1
    local right = #arr
    
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if arr[mid] == target then
            return mid
        elseif arr[mid] < target then
            left = mid + 1
        else
            right = mid - 1
        end
    end
    
    return -1
end

local function merge(left, right)
    local result = {}
    local i = 1
    local j = 1
    
    while i <= #left and j <= #right do
        if left[i] <= right[j] then
            table.insert(result, left[i])
            i = i + 1
        else
            table.insert(result, right[j])
            j = j + 1
        end
    end
    
    while i <= #left do
        table.insert(result, left[i])
        i = i + 1
    end
    
    while j <= #right do
        table.insert(result, right[j])
        j = j + 1
    end
    
    return result
end

local function mergeSort(arr)
    if #arr <= 1 then
        return arr
    end
    
    local mid = math.floor(#arr / 2)
    local left = {}
    local right = {}
    
    for i = 1, mid do
        table.insert(left, arr[i])
    end
    
    for i = mid + 1, #arr do
        table.insert(right, arr[i])
    end
    
    left = mergeSort(left)
    right = mergeSort(right)
    
    return merge(left, right)
end

local function generatePrimes(limit)
    local primes = {}
    for num = 2, limit do
        if isPrime(num) then
            table.insert(primes, num)
        end
    end
    return primes
end

local function sumArray(arr)
    local sum = 0
    for i = 1, #arr do
        sum = sum + arr[i]
    end
    return sum
end

local function averageArray(arr)
    if #arr == 0 then
        return 0
    end
    return sumArray(arr) / #arr
end

local function maxArray(arr)
    if #arr == 0 then
        return nil
    end
    local max = arr[1]
    for i = 2, #arr do
        if arr[i] > max then
            max = arr[i]
        end
    end
    return max
end

local function minArray(arr)
    if #arr == 0 then
        return nil
    end
    local min = arr[1]
    for i = 2, #arr do
        if arr[i] < min then
            min = arr[i]
        end
    end
    return min
end

local function reverseString(str)
    return string.reverse(str)
end

local function isPalindrome(str)
    local reversed = string.reverse(str)
    return str == reversed
end

local function countCharacter(str, char)
    local count = 0
    for i = 1, #str do
        if string.sub(str, i, i) == char then
            count = count + 1
        end
    end
    return count
end

local function replaceAll(str, old, new)
    return string.gsub(str, old, new)
end

local function trim(str)
    return string.match(str, "^%s*(.-)%s*$")
end

local function splitString(str, delimiter)
    local result = {}
    local pattern = "([^" .. delimiter .. "]+)"
    for match in string.gmatch(str, pattern) do
        table.insert(result, match)
    end
    return result
end

local function joinTable(arr, delimiter)
    return table.concat(arr, delimiter)
end

local function deepCopy(obj)
    if type(obj) ~= "table" then
        return obj
    end
    
    local copy = {}
    for key, value in pairs(obj) do
        copy[deepCopy(key)] = deepCopy(value)
    end
    
    return copy
end

local function tableSize(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

local function hasValue(tbl, value)
    for _, v in pairs(tbl) do
        if v == value then
            return true
        end
    end
    return false
end

local function filterTable(tbl, predicate)
    local result = {}
    for key, value in pairs(tbl) do
        if predicate(value) then
            table.insert(result, value)
        end
    end
    return result
end

local function mapTable(tbl, func)
    local result = {}
    for i, value in ipairs(tbl) do
        result[i] = func(value)
    end
    return result
end

local function reduceTable(tbl, func, initial)
    local accumulator = initial
    for _, value in ipairs(tbl) do
        accumulator = func(accumulator, value)
    end
    return accumulator
end

local function fibonacci_memo()
    local memo = {}
    return function(n)
        if memo[n] then
            return memo[n]
        end
        if n <= 1 then
            memo[n] = n
            return n
        end
        memo[n] = fibonacci_memo()(n - 1) + fibonacci_memo()(n - 2)
        return memo[n]
    end
end

local function gcd(a, b)
    while b ~= 0 do
        local temp = b
        b = a % b
        a = temp
    end
    return a
end

local function lcm(a, b)
    return (a * b) / gcd(a, b)
end

local function isPowerOfTwo(n)
    if n <= 0 then
        return false
    end
    return (n % 2 == 0) and isPowerOfTwo(n / 2) or n == 1
end

local function flatten(tbl)
    local result = {}
    
    local function flattenHelper(t)
        for _, value in ipairs(t) do
            if type(value) == "table" then
                flattenHelper(value)
            else
                table.insert(result, value)
            end
        end
    end
    
    flattenHelper(tbl)
    return result
end

local function transpose(matrix)
    if #matrix == 0 then
        return {}
    end
    
    local result = {}
    local numCols = #matrix[1]
    
    for col = 1, numCols do
        local newRow = {}
        for row = 1, #matrix do
            table.insert(newRow, matrix[row][col])
        end
        table.insert(result, newRow)
    end
    
    return result
end

local function matrixMultiply(a, b)
    local result = {}
    
    for i = 1, #a do
        result[i] = {}
        for j = 1, #b[1] do
            local sum = 0
            for k = 1, #b do
                sum = sum + (a[i][k] * b[k][j])
            end
            result[i][j] = sum
        end
    end
    
    return result
end

local function bubbleSort(arr)
    for i = 1, #arr do
        for j = 1, #arr - i do
            if arr[j] > arr[j + 1] then
                arr[j], arr[j + 1] = arr[j + 1], arr[j]
            end
        end
    end
    return arr
end

local function insertionSort(arr)
    for i = 2, #arr do
        local key = arr[i]
        local j = i - 1
        
        while j > 0 and arr[j] > key do
            arr[j + 1] = arr[j]
            j = j - 1
        end
        
        arr[j + 1] = key
    end
    
    return arr
end

local function selectionSort(arr)
    for i = 1, #arr - 1 do
        local minIdx = i
        for j = i + 1, #arr do
            if arr[j] < arr[minIdx] then
                minIdx = j
            end
        end
        
        if minIdx ~= i then
            arr[i], arr[minIdx] = arr[minIdx], arr[i]
        end
    end
    
    return arr
end

local function heapSort(arr)
    local function heapify(tbl, n, i)
        local largest = i
        local left = 2 * i
        local right = 2 * i + 1
        
        if left <= n and tbl[left] > tbl[largest] then
            largest = left
        end
        
        if right <= n and tbl[right] > tbl[largest] then
            largest = right
        end
        
        if largest ~= i then
            tbl[i], tbl[largest] = tbl[largest], tbl[i]
            heapify(tbl, n, largest)
        end
    end
    
    for i = math.floor(#arr / 2), 1, -1 do
        heapify(arr, #arr, i)
    end
    
    for i = #arr, 2, -1 do
        arr[1], arr[i] = arr[i], arr[1]
        heapify(arr, i - 1, 1)
    end
    
    return arr
end

local function shellSort(arr)
    local n = #arr
    local gap = math.floor(n / 2)
    
    while gap > 0 do
        for i = gap + 1, n do
            local temp = arr[i]
            local j = i
            
            while j > gap and arr[j - gap] > temp do
                arr[j] = arr[j - gap]
                j = j - gap
            end
            
            arr[j] = temp
        end
        
        gap = math.floor(gap / 2)
    end
    
    return arr
end

local function radixSort(arr)
    local maxNum = maxArray(arr)
    local exp = 1
    
    while math.floor(maxNum / exp) > 0 do
        local buckets = {}
        for i = 0, 9 do
            buckets[i] = {}
        end
        
        for i = 1, #arr do
            local digit = math.floor((arr[i] / exp) % 10)
            table.insert(buckets[digit], arr[i])
        end
        
        local index = 1
        for i = 0, 9 do
            for j = 1, #buckets[i] do
                arr[index] = buckets[i][j]
                index = index + 1
            end
        end
        
        exp = exp * 10
    end
    
    return arr
end

local function linearSearch(arr, target)
    for i = 1, #arr do
        if arr[i] == target then
            return i
        end
    end
    return -1
end

local function jumpSearch(arr, target)
    local n = #arr
    local step = math.floor(math.sqrt(n))
    local prev = 0
    
    while arr[math.min(step, n)] < target do
        prev = step
        step = step + math.floor(math.sqrt(n))
        if prev >= n then
            return -1
        end
    end
    
    while arr[prev + 1] < target do
        prev = prev + 1
        if prev == math.min(step, n) then
            return -1
        end
    end
    
    if arr[prev + 1] == target then
        return prev + 1
    end
    
    return -1
end

local function exponentialSearch(arr, target)
    if arr[1] == target then
        return 1
    end
    
    local i = 1
    while i < #arr and arr[i] < target do
        i = i * 2
    end
    
    return binarySearch(arr, target)
end

local class_mt = {}
class_mt.__index = class_mt

local function newObject(name, age, email)
    local object = setmetatable({}, class_mt)
    object.name = name
    object.age = age
    object.email = email
    return object
end

function class_mt:getName()
    return self.name
end

function class_mt:setName(name)
    self.name = name
end

function class_mt:getAge()
    return self.age
end

function class_mt:setAge(age)
    self.age = age
end

function class_mt:getEmail()
    return self.email
end

function class_mt:setEmail(email)
    self.email = email
end

function class_mt:display()
    print("Name: " .. self.name .. ", Age: " .. self.age .. ", Email: " .. self.email)
end

local function createConfig()
    return {
        debug = true,
        version = "1.0.0",
        timeout = 5000,
        retries = 3,
        endpoints = {
            api = "https://api.example.com",
            web = "https://www.example.com",
            static = "https://cdn.example.com"
        },
        database = {
            host = "localhost",
            port = 5432,
            user = "admin",
            password = "password",
            name = "mydb"
        }
    }
end

local function benchmarkSort(arr, sortFunc, name)
    local startTime = os.time()
    sortFunc(arr)
    local endTime = os.time()
    local elapsed = endTime - startTime
    print("Sorting with " .. name .. " took " .. elapsed .. " seconds")
    return elapsed
end

local function generateRandomArray(size, maxValue)
    local arr = {}
    for i = 1, size do
        table.insert(arr, math.random(1, maxValue))
    end
    return arr
end

local testArray = {64, 34, 25, 12, 22, 11, 90, 88, 45, 50, 32, 12, 99, 45, 23}
local largeArray = generateRandomArray(100, 1000)

-- Test sorting
print("Testing sorting algorithms...")
local sortedArray = deepCopy(testArray)
bubbleSort(sortedArray)

sortedArray = deepCopy(testArray)
insertionSort(sortedArray)

sortedArray = deepCopy(testArray)
selectionSort(sortedArray)

sortedArray = deepCopy(largeArray)
mergeSort(sortedArray)

-- Test searching
print("Testing search algorithms...")
local found = binarySearch(testArray, 25)

-- Test utility functions
print("Testing utility functions...")
local sum = sumArray(testArray)
local avg = averageArray(testArray)
local max = maxArray(testArray)
local min = minArray(testArray)

-- Test string functions
print("Testing string functions...")
local testString = "Hello World"
local reversed = reverseString(testString)
local isPalin = isPalindrome("racecar")
local count = countCharacter(testString, "o")
local replaced = replaceAll(testString, "World", "Lua")

-- Test table functions
print("Testing table functions...")
local numbers = {1, 2, 3, 4, 5}
local doubled = mapTable(numbers, function(x) return x * 2 end)
local evens = filterTable(numbers, function(x) return x % 2 == 0 end)
local product = reduceTable(numbers, function(acc, x) return acc * x end, 1)

-- Test math functions
print("Testing math functions...")
local prime5 = fibonacci(5)
local fact5 = factorial(5)
local is7Prime = isPrime(7)
local primeList = generatePrimes(50)
local gcdVal = gcd(48, 18)
local lcmVal = lcm(12, 18)

-- Test object creation
print("Testing object creation...")
local person1 = newObject("Alice", 30, "alice@example.com")
local person2 = newObject("Bob", 25, "bob@example.com")

person1:display()
person2:display()

-- Test configuration
print("Testing configuration...")
local config = createConfig()
print("API Endpoint: " .. config.endpoints.api)
print("Database Host: " .. config.database.host)

-- Additional complex functions
local function dfs(graph, node, visited)
    if visited[node] then
        return
    end
    visited[node] = true
    print("Visited: " .. node)
    
    if graph[node] then
        for _, neighbor in ipairs(graph[node]) do
            dfs(graph, neighbor, visited)
        end
    end
end

local function bfs(graph, startNode)
    local visited = {}
    local queue = {startNode}
    visited[startNode] = true
    
    while #queue > 0 do
        local node = table.remove(queue, 1)
        print("Visited: " .. node)
        
        if graph[node] then
            for _, neighbor in ipairs(graph[node]) do
                if not visited[neighbor] then
                    visited[neighbor] = true
                    table.insert(queue, neighbor)
                end
            end
        end
    end
end

local function dijkstra(graph, start)
    local distances = {}
    local visited = {}
    local previous = {}
    
    for node, _ in pairs(graph) do
        distances[node] = math.huge
        visited[node] = false
    end
    
    distances[start] = 0
    
    for _ = 1, tableSize(graph) do
        local minDist = math.huge
        local minNode = nil
        
        for node, dist in pairs(distances) do
            if not visited[node] and dist < minDist then
                minDist = dist
                minNode = node
            end
        end
        
        if minNode == nil then
            break
        end
        
        visited[minNode] = true
        
        if graph[minNode] then
            for neighbor, weight in pairs(graph[minNode]) do
                local newDist = distances[minNode] + weight
                if newDist < distances[neighbor] then
                    distances[neighbor] = newDist
                    previous[neighbor] = minNode
                end
            end
        end
    end
    
    return distances, previous
end

local function bellmanFord(graph, vertices, start)
    local distances = {}
    
    for _, v in ipairs(vertices) do
        distances[v] = math.huge
    end
    distances[start] = 0
    
    for _ = 1, #vertices - 1 do
        for u, edges in pairs(graph) do
            if distances[u] ~= math.huge then
                for v, weight in pairs(edges) do
                    if distances[u] + weight < distances[v] then
                        distances[v] = distances[u] + weight
                    end
                end
            end
        end
    end
    
    return distances
end

-- Test graph algorithms
print("Testing graph algorithms...")
local graph = {
    A = {B = 4, C = 2},
    B = {A = 4, C = 1, D = 5},
    C = {A = 2, B = 1, D = 8, E = 10},
    D = {B = 5, C = 8, E = 2},
    E = {C = 10, D = 2}
}

local visited = {}
dfs(graph, "A", visited)

bfs(graph, "A")

local distances, previous = dijkstra(graph, "A")

-- More string utilities
local function urlEncode(str)
    return string.gsub(str, "([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function urlDecode(str)
    return string.gsub(str, "%%([0-9a-fA-F][0-9a-fA-F])", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function camelCaseToSnakeCase(str)
    return string.gsub(str, "(%u)", function(char)
        return "_" .. string.lower(char)
    end)
end

local function snakeCaseToCamelCase(str)
    return string.gsub(str, "_(.)", function(char)
        return string.upper(char)
    end)
end

-- Test final batch
print("Testing final utilities...")
local encoded = urlEncode("Hello World!")
local decoded = urlDecode(encoded)
local snake = camelCaseToSnakeCase("helloWorld")
local camel = snakeCaseToCamelCase("hello_world")

print("All tests completed!")