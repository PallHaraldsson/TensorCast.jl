
const flag_list = Any[ :!, :assert, :cat, :glue, :strided, :lazy, :julienne, :batched]

#= TODO

* make sz a constant gensym()
* or better yet, generate :sz_i not sz[n], freeing from canon
* add ndims checks to sizeassert?
* pull the function in f(x)[i,j] out, to do it once
* make parse! take keywords sanely

@pretty @cast A[i\j\k] := B[i,j\k] + C[k] # this could have reshape(right, :) but not worth a fight?

=#

struct SizeDict
    dict::Dict{Any, Any}
    checks::Vector{Any}
    seen::Vector{Any}
end

SizeDict() = SizeDict(Dict{Any, Any}(), Any[], Any[])

"""
    flat, getafix, putsz, negated = parse!(sdict, A, outer, inner)

Use this for `A[outer...][inner...]`. 
* `flat` is a list of symbols, naming the indices, in order. 
* `negated` is the subset which had - in front. 
* `getafix` is the thing for making views of given input or target array, : in non-fixed directions. 
* `putsz` is a tuple of `sz[n]` and products, which you want for reshaping to the very final array; 
  the numbers `n` refer to position in `flat`. 
* `sdict::SizeDict` ends up with `sdict.dict[:i] = ` an expr for length of this index.
  To avoid saving these (if you don't have A yet) set `A = nothing`.

    parse!(sdict, A, outer, reduce_inner, true)

This is for `A[outer...] = sum(inner...) ...` LHS, which are allowed to have sum(a:2, ...) ranges. 
The allowranges flag *also* disables the use of `size(first(A), 2)` etc,
to disable `size(A,2)` set `A = nothing` again. 

    parse!(sdict, nothing, [], rex, true, flag_vector)

For dimensions & annotations. 
Will look for flags because it was given something to push them into. 
You should now do this first, so that `sdict` is most likely to have these (neater) entries. 
They are added using savesize!(sdict,...) which now puts later sizes into list of checks. 
"""
function parse!(sdict::SizeDict, A, outer, inner, allowranges=false, flags=nothing)

    flat = Any[]
    getafix = Any[]
    putsz = Any[]
    negated = Any[]

    ### INNER dimensions come first in flat
    for (din, ind) in enumerate(inner)

        # look for flags only in rex case
        if flags != nothing && ind in flag_list # global const
            push!(flags, ind)
            continue
        end

        # in rex or sum(a, b:3, c), some indices may have explicit ranges
        if allowranges 

            if @capture(ind , i_:ilength_ )
                savesize!(sdict, i, ilength)
                if flags != nothing
                    push!(flags, :assert) # turn on size checks if you can
                else
                    # for sum(i:3, j) can't see flags, so can't do that, sorry
                end
            else
                i = ind    # replace nothing from @capture
            end
            push!(flat, i) # all need to go into flat!

        # for simple slicing, always want iflat, but size(first(A),d) only if we know A. 
        else
            i = stripminus!(negated, ind) # now i isa Symbol
            push!(flat, i)

            if !isnothing(A) # only save these if we can access A. 
                savesize!(sdict, i, :( size(first($A), $din) ) ) 
            end
        end
    end

    ### OUTER dimensions never allow flags or ranges,
    # but do allow tuples etc, and fixed indices.
    for (dout, ind) in enumerate(outer)
        if isconstant(ind)              # then it's a constant slice,
            # removing this "if" will make _ cases produce rview()... but it's slower! 
            if ind == :_                # treat _ almost like 1, but possibly with a check
                if !isnothing(A)
                    str = "direction marked _ must have size 1"
                    push!(sdict.checks, :(TensorCast.@assert_ size($A, $dout) == 1 $str) )
                end
                ind = 1
            end
            if ind isa Expr             # constant slice with $c
                @assert ind.head == :($)
                ind = ind.args[1]
            end
            push!(getafix, ind)         # so when we view(A, getafix...) we need it
            push!(putsz, 1)             # or if driving the other direction, make size=1.
        else
            push!(getafix, Colon() )           # and we want this on the list:
            ind = stripminus!(negated, ind) # this looks inside for -, and returns Symbol or Vector{Symbol}
            if !isnothing(A)
                savesize!(sdict, ind, :( size($A, $dout) ) )
            end

            d = length(flat) + 1 # index in flat of ind, or ind[1]. 
            push!(putsz, szwrap(ind, d)) 

            push_or_append!(flat, ind) 
        end
    end

    return flat, getafix, putsz, negated
end

isconstant(i::Int) = true
isconstant(i::Symbol) = i == :_ 
isconstant(ex::Expr) = ex.head == :($)

function findcheck(i::Symbol, ind::Vector, where=nothing)
    d = findfirst(isequal(i), ind)
    d isa Nothing && throw(MacroError("can't find index $i", where))
    return d
end
findcheck(i::Expr, ind::Vector, where=nothing) = 
    throw(MacroError("don't know what to do with index $i, expected a single symbol", where))

function savesize!(store::SizeDict, ind, long)
    if !haskey(store.dict, ind) # then we don't yet have a size for this index (or tuple)
        store.dict[ind] = long
    else                        # we have seen it before,
        if isa(ind, Symbol)     # but list of checks is only for actual indices
            str = "range of index $ind must agree"
            push!(store.checks, :(TensorCast.@assert_ $(store.dict[ind]) == $long $str) )
        end
    end
end

push_or_append!(list, ind::Symbol) = push!(list, ind)
push_or_append!(list, inds::Vector) = append!(list, inds)

"""
    stripminus(negated, i)

For any index, or vector of indices, or vector of indices containing tuples / backslash combos, 
this pushes every letter with a minus in front into negated list.

It returns an index, or a tidied-up vector of indices, in which tuples etc have become vectors.   
"""
stripminus!(negated::Vector, ind::Symbol) = ind  # get one Symol & you're done

stripminus!(negated::Vector, ind::Int) = throw(MacroError("can't handle fixed index $ind here"))

function stripminus!(negated::Vector, ind::Expr)
    # minus one index
    if @capture(ind, -i_Symbol)
        push!(negated, i)       # add that to the negated list
        return i                # and go home. 

    # tuple notation
    elseif @capture(ind, -(ijk__,) )
        ijkplus = stripminus!(negated, ijk)
        append!(negated, ijkplus)

    elseif @capture(ind, (ijk__,) )

    # backslash notation -- if you want more than four \ then I'm impressed! TODO make recursive
    elseif @capture(ind, i_\j_\k_\l_\m )
        ijk = Any[i,j,k,l,m]
    elseif @capture(ind, i_\j_\k_\l_ )
        ijk = Any[i,j,k,l]
    elseif @capture(ind, i_\j_\k_ )
        ijk = Any[i,j,k]
    elseif @capture(ind, i_\j_ )
        ijk = Any[i,j]

    elseif @capture(ind, i_⊗j_⊗k_⊗l_⊗m )
        ijk = Any[i,j,k,l,m]
    elseif @capture(ind, i_⊗j_⊗k_⊗l_ )
        ijk = Any[i,j,k,l]
    elseif @capture(ind, i_⊗j_⊗k_ )
        ijk = Any[i,j,k]
    elseif @capture(ind, i_⊗j_ )
        ijk = Any[i,j]

    else 
        throw(MacroError("stuck on $ind, doesn't look like a valid index, or set of indices"))
    end

    # now we have a vector ijk of symbols, or expressions :(-i), no more
    return Any[ stripminus!(negated, i) for i in ijk ]
end

szwrap(i::Symbol, d::Int) = :( sz[$d] )
# szwrap(ijk::Vector, d::Int) = :( *($([ :(sz[$n]) for n=d:(d+length(ijk)-1) ]...)) )
szwrap(ijk::Vector, d::Int) = :( TensorCast.star($([ :(sz[$n]) for n=d:(d+length(ijk)-1) ]...)) )

"""
    oddunique(negated)

Returns a list in which anything repeated evenly many times has been removed, then `unique`. 
"""
function oddunique(negated)  # -1 * -1 = +1
    set = Set{Symbol}()
    for i in negated
        if i in set
            pop!(set, i)
        else
            push!(set, i)
        end
    end
    Any[ i for i in set ]
end

"""
    checkrepeats(flat)

Throws an error if there are repeated indices. 
Also a good place to check whether flat is flat... e.g. A[i][j\\k] will arrive here
"""
function checkrepeats(flat, msg="", where=nothing)
    once = Set{Symbol}()
    twice = Set{Symbol}()
    for i in flat
        if i != nothing
            isa(i, Symbol) || throw(MacroError("can't handle index $i, expected a single symbol" * msg, where))

            if i in once
                push!(twice, i)
            else
                push!(once, i)
            end
        end
    end
    if length(twice) > 0
        str = join(twice, ", ")
        throw(MacroError("index $str repeated" * msg, where))
    end
    nothing
end


"""
    sizeinfer(store, icannon, where, leaveone=true)

This is the point of SizeDict. 
The goal is to produce a canonical vector of sizes, corresponding to vector of symbols icannon. 
If these sizes are known, easy!

But for unknown ones, we do a second pass, looking for entries in sizedict like [:i, :j]
which come from tuples of indices, for which we know the product of their dimensions. 
"""
function sizeinfer(store::SizeDict, icanon::Vector, where=nothing, leaveone = true)
    sizes = Any[ (:) for i in icanon ]

    # first pass looks for single indices whose lengths are known directly
    for pair in store.dict
        if isa(pair.first, Symbol)  
            d = findcheck(pair.first, icanon, where)
            sizes[d] = pair.second  # so write it into the answer
        end
    end

    if leaveone && count(isequal(:), sizes) < 2 
        V && count(isequal(:), sizes)==1 &&  @info "sizeinfer -- leaving one : in sizes" repr(sizes)
        return sizes 
    end
    V && @info "sizeinfer -- first pass" sizes

    # second pass looks for tuples (whose product-length is known) where exactly one entry has unknown length
    for pair in store.dict
        if isa(pair.first, Vector)
            known = haskey.(Ref(store.dict), pair.first)

            if sum(.!known) == 1    # bingo! now work out its size:
                num = pair.second
                denfacts = [ store.dict[i] for i in pair.first[known] ]
                if length(denfacts) > 1
                    den = :( *($(denfacts...)) )
                else
                    den = :( $(denfacts[1]) )
                end
                rat = :( $num ÷ $den )

                d = findcheck(first(pair.first[.!known]), icanon, where)
                sizes[d] = rat      # save that size

                str = "inferring range of $(icanon[d]) from range of $(join(pair.first, " ⊗ "))" 
                push!(store.checks, :( TensorCast.@assert_ rem($num, $den)==0 $str) )
            end
        end
    end
    V && @info "sizeinfer -- second pass" sizes

    unknown = Any[ i for (d,i) in enumerate(icanon) if sizes[d] == (:) ]
    str = join(unknown, ", ")
    length(unknown) <= 1 || throw(MacroError("unable to infer ranges for indices $str", where))

    return sizes
end


"""
    star(x,y,...)

Like `*` but intended for multiplying sizes, and understands that `:` is a wildcard. 
"""
star(x,y) = *(x,y)
star(::Colon,y) = Colon()
star(x,::Colon) = Colon()
star(x,y,zs...) = star(star(x,y), zs...)

"""
    needview!([:, 3, :])   # true, need view(A, :,3,:)
    needview!([:, :_, :])  # false, can use rview(A, :,1,:)

Mutates the given vector, replacing symbol `:_` with `1`. 
If the vector contains only colons & underscores, then the result is suitable for use with `rview`,
but if not, we need a real view, so it returns `true`.
"""
function needview!(getafix::Vector)
    out = false
    for i=1:length(getafix)
        if getafix[i] == :_ 
            getafix[i] = 1
        elseif getafix[i] isa Int || getafix[i] isa Symbol
            out = true
        elseif getafix[i] isa Colon
        else
            error("this should never happen, getafix[i] = ",getafix[i])
        end
    end
    out
end

"""
    @assert_ cond str

Like `@assert`, but prints both the given string and the condition. 
"""
macro assert_(ex, str)
    strex = Main.Base.string(ex)
    msg = str * ": " * strex
    return esc(:($ex || throw(DimensionMismatch($msg))))
end

function unparse(str::String, exs...)
    @capture(exs[1], left_ = right_ ) && return string(str, " ", left, " = ", right, "  ", join(exs[2:end],"  "))
    @capture(exs[1], left_ := right_ ) && return string(str, " ", left, " := ", right, "  ", join(exs[2:end],"  "))
    @capture(exs[1], left_ |= right_ ) && return string(str, " ", left, " |= ", right, "  ", join(exs[2:end],"  "))
    @capture(exs[1], left_ == right_ ) && return string(str, " ", left, " == ", right, "  ", join(exs[2:end],"  "))
    return string(exs)
end

function m_error(str::String, where=nothing)
    if where == nothing
        @error str
    else
        @error str  input=where.str _module=where.mod  _line=where.src.line  _file=string(where.src.file)
    end
end

struct MacroError <: Exception
    msg::String
    where::Union{Nothing, NamedTuple}
    MacroError(msg::String, where=nothing) = new(msg, where)
end

function Base.showerror(io::IO, err::MacroError)
    print(io, err.msg)
    if err.where != nothing
        printstyled(io, " \n    ", err.where.str; color = :normal)# :blue)
    end
end



