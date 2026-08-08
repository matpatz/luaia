local a = {
    sub1 = {
        a = 32,
        ["bnm"] = 12,
    },
    sub2 = {
        ["1"] = "a2",
        ["32"] = "a1",
    },
    m = true
}

if a.m then
    print(a.sub1.a + 32)
end