export @cast_str, @reduce_str, @matmul_str

"""
    cast" Z_ij := A_i + B_j "

String macro version of `@cast`, which translates things like `"A_ijk" == A[i,j,k]`.
Indices should be single letters, except for primes, for example:
```
julia> @pretty cast" X_αβ' = A_α3β' * log(B_β'\$k)"
# @cast  X[α,β′] = A[α,3,β′] * log(B[β′,\$k])
begin
    local kangaroo = view(A, :, 3, :)
    local turtle = transpose(view(B, :, k))
    X .= @. kangaroo * log(turtle)
end
```
Underscores (trivial dimensions) and colons (for mapslices) are also understood:
```
julia> @pretty cast" Y_ijk := f(A_j:k)_i + B_i_k + (C_k)_i"
# @cast  Y[i,j,k] := f(A[j,:,k])[i] + B[i,_,k] + C[k][i]
```
Operators `:=` and `=` work as usual, as do options.
There are similar macros `reduce"Z_i = Σ_j A_ij"` and `matmul"Z_ik = Σ_j A_ij * B_jk"`.
"""
macro cast_str(str::String)
    Meta.parse("@cast " * cast_string(str)) |> esc
end
macro tensor_str(str::String)
    Meta.parse("@tensor " * cast_string(str)) |> esc
end
macro einsum_str(str::String)
    Meta.parse("@einsum " * cast_string(str)) |> esc
end

"""
    reduce" Z_i := sum_j A_ij + B_j "

String macro version of `@reduce`.
Indices should be single letters, except for primes, and constants.
You may write \\Sigma `Σ` for `sum` (and \\Pi `Π` for `prod`):
```
julia> @pretty reduce" W_i = Σ_i' A_ii' / B_i'3^2  lazy"
# @reduce  W[i] = sum(i′) A[i,i′] / B[i′,3]^2  lazy
begin
    local mallard = orient(view(B, :, 3), (*, :))
    sum!(W, @__dot__(lazy(A / mallard ^ 2)))
end
```
"""
macro reduce_str(str::String)
    Meta.parse(reduce_string(str)) |> esc
end

macro matmul_str(str::String)
    Meta.parse(matmul_string(str)) |> esc
end

function cast_string(str)
    replace(str, r"_([\w\d\$\'\′\:\⊗]+)" => indexsquare)
end

function reduce_string(str::String)
    str2 = replace(str, r"=\s+\w+_[\w\'\′\:\⊗]+" => indexfun)
    str3 = replace(str2, r"_([\w\d\$\'\′\:\⊗]+)" => indexsquare)
    "@reduce " * str3
end

"""
    matmul" Z_i := Σ_j A_ij + B_j "

String macro version of `@matmul`, accepts `Σ_j` or `sum_j`.
```
julia> @pretty matmul" Z_ij := Σ_k A_ik + B_kj "
# @matmul  Z[i,j] := sum(k) A[i,k] + B[k,j]
```
"""
function matmul_string(str::String)
    str2 = replace(str, r"=\s+sum_[\w\'\′\:\⊗]+" => indexfun)
    str3 = replace(str2, r"=\s+Σ_[\w\'\′\:\⊗]+" => indexfun)
    str4 = replace(str3, r"_([\w\d\$\'\′\:\⊗]+)" => indexsquare)
    "@matmul " * str4
end

function indexcomma(str)
    list = []
    for c in collect(str)

        # primes
        if (c=='\'') || (c=='′') && length(list)>0
            list[end] *= "′"

        # constants
        elseif length(list)>0 && list[end] =='\$'
            list[end] = "\$" * c

        # tensors
        elseif length(list)>0 && c=='⊗'
            list[end] *= "⊗"
        elseif length(list)>0 && list[end][end]=='⊗'
            list[end] *= c

        else
            push!(list, string(c))
        end
    end
    join(list, ',')
end

isnumber(c::Char) = '0' <= c <= '9'
isnumber(s::String) = all(isnumber, collect(s))

function indexsquare(str)
    @assert str[1] == '_'
    "[" * indexcomma(str[2:end]) * "]"
end

function indexfun(str)
    @assert str[1] == '='

    start, ind = split(str, '_')
    fun = split(start, ('=', ' '))[end]

    fun == "Σ" ? fun = "sum" :
    fun == "Π" ? fun = "prod" : nothing

    "= " * fun * "(" * indexcomma(ind) * ")"
end

