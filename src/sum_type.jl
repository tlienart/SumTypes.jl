macro sum_type(T, blk, _hide_variants=:(hide_variants = false))
    if _hide_variants isa Expr && _hide_variants.head == :(=) && _hide_variants.args[1] == :hide_variants
        hide_variants = _hide_variants.args[2]
    else
        error(ArgumentError("Invalid option $_hide_variants\nThe only current allowed option is hide_variants=true or hide_variants=false`"))
    end
    
    @assert blk isa Expr && blk.head == :block
    T_name, T_params, T_params_constrained = if T isa Symbol
        T, [], []
    elseif T isa Expr && T.head == :curly
        T.args[1], (x -> x isa Expr && x.head == :(<:) ? x.args[1] : x).(T.args[2:end]), T.args[2:end]
    end
    T_nameparam = isempty(T_params) ? T : :($T_name{$(T_params...)})
    filter!(x -> !(x isa LineNumberNode), blk.args)
    
    constructors = generate_constructor_data(T_name, T_params, T_params_constrained, T_nameparam, hide_variants, blk)
    
    if !allunique(map(x -> x.name, constructors))
        error("constructors must have unique names, got $(map(x -> x.name, constructors))")
    end

    out, converts, singletons = generate_constructor_exprs(T_name, T_params, T_params_constrained, T_nameparam, constructors)
    ex = generate_sum_struct_expr(T, T_name, T_params, T_params_constrained, T_nameparam, constructors, singletons)
    push!(out.args, ex)
    push!(out.args, converts...) # Conversion statements requre T to be defined
    esc(out)
end

function generate_sum_struct_expr(T, T_name, T_params, T_params_constrained, T_nameparam, constructors, singletons)
        
    con_nameparams  = (x -> x.nameparam ).(constructors)
    con_gnameparams = (x -> x.gnameparam).(constructors)
    con_names       = (x -> x.name      ).(constructors)
    con_gnames      = (x -> x.gname     ).(constructors)
    
    data_fields = map(constructors) do nt
        (name, params, nameparam, field_names, types, params_uninit, params_constrained, singleton, gname, gnameparam) = nt
        if singleton
            :($name :: $gnameparam)
            #nothing
        else
            :($name :: Union{$gnameparam, Nothing})
        end
    end
    sum_struct_def = Expr(:struct, false, T, Expr(:block, data_fields..., :($tag::Symbol), :(1 + 1)))

    if_nest_unwrap = mapfoldr(((cond, data), old) -> Expr(:if, cond, data, old), constructors, init=:(error("invalid tag"))) do nt
        (name, _, _, _, _, _, _, _, _, gnameparam) = nt
        :(tag === $(QuoteNode(name))), :($getfield(x, $(QuoteNode(name))) :: $gnameparam) 
    end
    ex = quote
        $sum_struct_def
        $singletons
        $SumTypes.constructors(::Type{$T_name}) =
            $NamedTuple{$tags($T_name)}($(Expr(:tuple, (nt.singleton ? nt.gnameparam : nt.gname for nt ∈ constructors)...)))
        $SumTypes.constructors(::Type{$T_nameparam}) where {$(T_params...)} =
            $NamedTuple{$tags($T_name)}($(Expr(:tuple,
                                               (nt.gnameparam for nt ∈ constructors)...)))
        $SumTypes.constructors_Union(::Type{$T_nameparam}) where {$(T_params...)}= $Union{$((nt.nameparam for nt ∈ constructors)...)}
        $SumTypes.constructors_Union(::Type{$T_name}) = $Union{$((nt.singleton ? nt.nameparam : nt.name for nt ∈ constructors)...)}
        $SumTypes.is_sumtype(::Type{<:$T_name}) = true
        $SumTypes.unwrap(x::$T_nameparam) where {$(T_params...)}= let tag = getfield(x, $(QuoteNode(tag)))
            $if_nest_unwrap
        end
        #$Base.adjoint(::Type{T}) where {T <: $T_name} = $SumTypes.constructors(T)
        $Base.adjoint(::Type{$T_name}) =
            $NamedTuple{$tags($T_name)}($(Expr(:tuple, (nt.gname  for nt ∈ constructors)...)))
        
        $Base.adjoint(::Type{$T_nameparam}) where {$(T_params...)} =
            $NamedTuple{$tags($T_name)}($(Expr(:tuple, (nt.singleton ? :($T_nameparam($(nt.gname))) : nt.gnameparam  for nt ∈ constructors)...)))
        $Base.show(io::IO, x::$T_name) = $show_sumtype(io, x)
        $Base.show(io::IO, m::MIME"text/plain", x::$T_name) = $show_sumtype(io, m, x)
        
        #$SumTypes.deparameterize(::Type{<:$T_name}) = $T_name
        $SumTypes.tags(::Type{<:$T_name}) = $(Expr(:tuple, map(x -> QuoteNode(x.name), constructors)...))
        Base.:(==)(x::$T_name, y::$T_name) = $unwrap(x) == $unwrap(y)
    end
    foreach(constructors) do (name, params, nameparam, field_names, types, params_uninit, params_constrained, singleton, gname, gnameparam)
        cons = quote
            $SumTypes.constructor(::Type{$T_name}, ::Type{Val{$(QuoteNode(name))}}) = $(singleton ? gnameparam : gname)
            $SumTypes.constructor(::Type{$T_nameparam}, ::Type{Val{$(QuoteNode(name))}}) where {$(T_params...)} = $gnameparam
        end
        push!(ex.args, cons)
    end
    ex
end

function generate_constructor_exprs(T_name, T_params, T_params_constrained, T_nameparam, constructors)
    out = Expr(:toplevel)
    converts = []
    singletons = Expr(:block)
    foreach(constructors) do (name, params, nameparam, field_names, types, params_uninit, params_constrained, singleton, gname, gnameparam)
        nameparam_constrained = isempty(params) ? name : :($name{$(params_constrained...)})
        gnameparam_constrained = isempty(params) ? gname : :($gname{$(params_constrained...)})
        T_uninit = isempty(T_params) ? T_name : :($T_name{$(params_uninit...)})
        T_init = isempty(T_params) ? T_name : :($T_name{$(T_params...)})
        if singleton
            T_con_fields = map(constructors) do (_name, _, _nameparam, _, _, _, _, singleton, _gname, _gnameparam)
                default = singleton ? :($_gnameparam()) : nothing
                _name == name ? Singleton{gname}() : default
            end
            ex = quote
                const $gname = $(Expr(:new, T_uninit, T_con_fields..., QuoteNode(name)))
                # $SumTypes.parent(::Type{$Singleton{$(QuoteNode(name))}}) = $T_name
            end
            push!(singletons.args, ex)
        else
            field_names_typed = map(field_names, types) do name, type
                :($name :: $type)
            end
            T_con_fields = map(constructors) do (_name, _, _nameparam, _, _, _, _, singleton, _gname, _gnameparam)
                default = singleton ? :($_gnameparam()) : nothing
                _name == name ? Expr(:new, gnameparam, field_names...) : default
            end
            T_con = :($gnameparam($(field_names_typed...)) where {$(params_constrained...)} =
                $(Expr(:new, T_uninit, T_con_fields..., QuoteNode(name))))
            
            T_con_fields2 = map(constructors) do (_name, _, _nameparam, _, _, _, _, singleton, _gname, _gnameparam)
                default = singleton ? :($_gnameparam()) : nothing
                s = Expr(:new, gnameparam, [:($convert($type, $field_name)) for (type, field_name) ∈ zip(types, field_names)]...)
                _name == name ? s : default
            end
            T_con2 = :($gnameparam($(field_names...)) where {$(params_constrained...)} =
                $(Expr(:new, T_uninit, T_con_fields2..., QuoteNode(name))))
            
            unsafe_con = :($gnameparam(::$Unsafe, $(field_names_typed...)) where {$(params_constrained...)} = new{$(params...)}($(field_names...)))
            struct_def = Expr(:struct, false, gnameparam_constrained, 
                              Expr(:block, field_names_typed..., T_con, T_con2, unsafe_con))
            maybe_no_param = if !isempty(params)
                :($gname($(field_names_typed...)) where {$(params...)} = $gnameparam($(field_names...)))
            end
            ex = quote
                $struct_def
                $maybe_no_param
                @inline $Base.iterate(x::$gname, s = 1) = s ≤ fieldcount($gname) ? (getfield(x, s), s + 1) : nothing
                $Base.indexed_iterate(x::$gname, i::Int, state=1) = (Base.@_inline_meta; (getfield(x, i), i+1))
                $SumTypes.parent(::Type{<:$gname}) = $T_name
                function Base.:(==)(x::$gname, y::$gname)
                    $(foldl((old, field) -> :($old && $isequal($getfield(x, $field), $getfield(y, $field))), QuoteNode.(field_names), init=true))
                end
            end
            push!(out.args, ex)
        end
        if_nest = mapfoldr(((cond, data), old) -> Expr(:if, cond, data, old), constructors, init=:(error("invalid tag"))) do (name,
                                                                                                                              _,
                                                                                                                              nameparam,
                                                                                                                              _, _, _, _,
                                                                                                                              _,
                                                                                                                              gname,
                                                                                                                              gnameparam)
            data =  map(constructors) do (_name, _, _nameparam, _, _, _, _, singleton, _gname, _gnameparam)
                default = singleton ? :($_gnameparam()) : nothing
                _name == name ? :($getfield(x, $(QuoteNode(name))) :: $gnameparam) : default
            end
            :(tag === $(QuoteNode(name))), Expr(:new, T_init, data..., :tag)
        end
        if true#!isempty(T_params)
            push!(converts,
                  :($Base.convert(::Type{$T_init}, x::$T_uninit) where {$(T_params...)} = $(Expr(:block,
                                                                                                 :(tag = getfield(x, $(QuoteNode(tag)) )), if_nest ))))
            push!(converts, :($T_init(x::$T_uninit) where {$(T_params...)} = $convert($T_init, x)))
        end
    end
    out, converts, singletons
end

function generate_constructor_data(T_name, T_params, T_params_constrained, T_nameparam, hide_variants, blk::Expr)
    constructors = []
    for con_ ∈ blk.args
        con_ isa LineNumberNode && continue
        if con_ isa Symbol
            if hide_variants
                gname = Symbol("#", T_name, "#", con_)
            else
                gname = con_
            end
            nt = (; name = con_,
                  params = [],
                  nameparam = Singleton{con_},
                  field_names = [],
                  types = [],
                  params_uninit=[Uninit for _ ∈ T_params],
                  params_constrained = [],
                  singleton = true,
                  gname = gname,
                  gnameparam = Singleton{gname},
                  )
            push!(constructors, nt)
        else
            con::Expr = con_
            if con.head != :call
                error("Malformed variant $con_")
            end
            con_name = con.args[1] isa Expr && con.args[1].head == :curly ? con.args[1].args[1] : con.args[1]
            con_params = (con.args[1] isa Expr && con.args[1].head == :curly) ? con.args[1].args[2:end] : []
            if !issubset(con_params, T_params)
                error("constructor parameters ($con_params) for $con_name, not a subset of sum type parameters $T_params")
            end
            #@assert con_params == T_params "constructors currently must have same parameters as the sum type. Got $T and $(con.args[1])"
            con_params_uninit = let v = copy(con_params)
                for i ∈ eachindex(T_params)
                    if T_params[i] ∉ con_params
                        insert!(v, i, Uninit)
                    end
                end
                v
            end
            con_params_constrained = [T_params_constrained[i] for i ∈ eachindex(con_params_uninit) if con_params_uninit[i] != Uninit]
            con_nameparam = isempty(con_params) ? con_name : :($con_name{$(con_params...)})
            con_field_names = map(enumerate(con.args[2:end])) do (i, field)
                @assert field isa Symbol || (field isa Expr && field.head == :(::)) "malformed constructor field $field"
                if field isa Symbol
                    field
                elseif  length(field.args) == 1
                    Symbol(:_, i)
                elseif length(field.args) == 2
                    field.args[1]
                end
            end
            con_field_types = map(con.args[2:end]) do field
                @assert field isa Symbol || (field isa Expr && field.head == :(::)) "malformed constructor field $field"
                if field isa Symbol
                    Any
                elseif  length(field.args) == 1
                    field.args[1]
                elseif length(field.args) == 2
                    field.args[2]
                end
            end
            if hide_variants
                gname = Symbol("#", T_name, "#", con_name)
                gnameparam = isempty(con_params) ? gname : :($gname{$(con_params...)})
            else
                gname = con_name
                gnameparam = con_nameparam
            end
            nt = (
                name=con_name,
                params=con_params,
                nameparam = con_nameparam,
                field_names=con_field_names,
                types=con_field_types,
                params_uninit=con_params_uninit,
                params_constrained = con_params_constrained,
                singleton = false,
                gname = gname,
                gnameparam = gnameparam,
            )
            push!(constructors, nt)
        end
    end
    constructors
end
