using Test, SumTypes
#-------------------
@sum_type Foo begin
    Bar(::Int)
    Baz(::Float64)
end
#-------------------
@sum_type Either{A, B} begin
    Left{A}(::A)
    Right{B}(::B)
end
#-------------------
@sum_type List{A, L} begin 
    Nil
    Cons{A, L}(::A, ::L) 
end

List(first, rest...) = Cons(first, List(rest...))
List() = Nil

function Base.Tuple(l::List)
    @cases l begin
        Nil => ()
        Cons(a, b) => (a, Tuple(b)...)
    end 
end 
function Base.show(io::IO, l::List)
    print(io, "List", Tuple(l))
end
#-------------------
@testset "Basics  " begin
    @test Bar(1) isa Foo
    @test_throws MethodError Foo(1)

    function either_test(x::Either)
        let x::Either{Int, Int} = x
            @cases x begin
                Left(l) => l + 1
                Right(r) => r - 1
            end
        end
    end
    function either_test_incomp(x::Either)
        let x::Either{Int, Int} = x
            @cases x begin
                Left(l) => l + 1
                Right(r) => r - 1
            end
        end
    end
    @test either_test(Left(1)) == 2
    @test either_test(Right(1)) == 0
    @test_throws ErrorException either_test_incomp(Left(1))

    let x = Left([1]), y = Left([1.0]), z = Right([1])
        @test x == y
        @test x != z
    end
    
    @test_throws MethodError Left{Int}("hi")
    @test_throws MethodError Right{String}(1)
    @test Left{Int}(0x01) === Left{Int}(1)

    @test Nil isa List{Uninit, Uninit}
    @test Cons(1, Cons(1, Nil)) isa List{Int, List{Int, List{Uninit, Uninit}}}
    @test Tuple(List(1, 2, 3, 4, 5)) == (1, 2, 3, 4, 5)
end

#--------------------------------------------------------
@sum_type AT begin
    A(common_field::Int, a::Bool, b::Int)
    B(common_field::Int, a::Int, b::Float64, d::Complex)
    C(common_field::Int, b::Float64, d::Bool, e::Float64, k::Complex{Real})
    D(common_field::Int, b::Any)
end

A(;common=1, a=true, b=10) = A(common, a, b) 
B(;common=1, a=1, b=1.0, d=1 + 1.0im) = B(common, a, b, d)
C(;common=1, b=2.0, d=false, e=3.0, k=Complex{Real}(1 + 2im)) = C(common, b, d, e, k)
D(;common=1, b=:hi) = D(common, b)

foo!(xs) = for i in eachindex(xs)
    xs[i] = @cases xs[i] begin
        A => B()
        B => C()
        C => D()
        D => A()
    end
end


# #CI Doesn't like this test so just uncomment it for local testing
if !haskey(ENV, "CI") && ENV["CI"] != "true"
    @testset "Allocation-free @cases" begin
        xs = map(x->rand((A(), B(), C(), D())), 1:10000);
        foo!(xs)
        @test @allocated(foo!(xs)) == 0
    end
end

#--------------------------------------------------------

@sum_type Hider{T} begin
    A
    B{T}(::T)
end hide_variants = true

@sum_type Hider2 begin
    A
    B
end hide_variants = true

@testset "hidden variants" begin
    @test Hider{Int}'.A isa Hider{Int}
    @test Hider'.A isa Hider{SumTypes.Uninit}
    @test Hider'.A != A
    @test Hider'.B != B

    @test 1 == @cases Hider'.A begin
        A => 1
        B(a) => a
    end
    @test 2 == @cases Hider'.B(2) begin
        A => 1
        B(a) => a
    end

    @test Hider2'.A isa Hider2
    @test Hider2'.B isa Hider2
    @test Hider2'.A != A
    @test Hider2'.B != B

    @test 1 == @cases Hider2'.A begin
        A => 1
        B(a) => a
    end
    @test 2 == @cases Hider2'.B begin
        A => 1
        B => 2
    end
end

@sum_type Either2{A, B} begin
    Left{A}(::A)
    Right{B}(::B)
end hide_variants = true

SumTypes.show_sumtype(io::IO, x::Either2) = @cases x begin
    Left(a) => print(io, "L($a)")
    Right(a) => print(io, "R($a)")
end

SumTypes.show_sumtype(io::IO, ::MIME"text/plain", x::Either2) = @cases x begin
    Left(a) => print(io, "The Leftestmost Value: $a")
    Right(a) => print(io, "The Rightestmost Value: $a")
end

@testset "printing  " begin
    @test repr(Left(1)) ∈  ("Left(1)::Either{Int64, Uninit}", "Left(1)::Either{Int64,Uninit}") 
    @test repr("text/plain", Right(3)) ∈ ("Right(3)::Either{Uninit, Int64}", "Right(3)::Either{Uninit,Int64}")

    let Left = Either2'.Left, Right = Either2'.Right
        @test repr("text/plain", Left(1)) == "The Leftestmost Value: 1"
        @test repr(Right(3)) == "R(3)"
    end
end
