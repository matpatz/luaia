local _0 = (function()
	return (function(A)
		return (function(B)
			return (function(C)
				local T = {}

				T[1] = (((A)))
				T[2] = (((B)))
				T[3] = (((C)))

				local I = 1
				local Sum = 0

				while (((true))) do
					if not (T[I]) then
						break
					end

					Sum = (((((Sum + T[I])))))
					I += 1

					if (((false))) then
						continue
					end
				end

				return (((((((Sum)))))))
			end)
		end)
	end)
end)()(5)(10)(15)

print(_0)