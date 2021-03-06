##
# Implements contextual dispatch through Cassette.jl
# Goals:
# - Rewrite common CPU functions to appropriate GPU intrinsics
#
# TODO:
# - error (erf, ...)
# - pow
# - min, max
# - mod, rem
# - gamma
# - bessel
# - distributions
# - unsorted

using Cassette

##
# Important for inference to not be able to see the constant value
##
@inline function unknowably_false()
    Base.llvmcall("ret i8 0", Bool, Tuple{})
end

const INTERACTIVE = haskey(ENV, "GPUIFYLOOPS_INTERACTIVE") && ENV["GPUIFYLOOPS_INTERACTIVE"] == "1"

##
# Forces inlining on everything that is not marked `@noinline`
# Cassette has a #265 issue, let's try to work around that.
##
function transform(ctx, ref)
    CI = ref.code_info
    noinline = any(@nospecialize(x) ->
                       Core.Compiler.isexpr(x, :meta) &&
                       x.args[1] == :noinline,
                   CI.code)
    CI.inlineable = !noinline

    @static if INTERACTIVE
    # 265 fix, insert a call to the original method
    # that we later will remove with LLVM's DCE
    unknowably_false = GlobalRef(@__MODULE__, :unknowably_false)
    Cassette.insert_statements!(CI.code, CI.codelocs,
      (x, i) -> i == 1 ?  4 : nothing,
      (x, i) -> i == 1 ? [
          Expr(:call, Expr(:nooverdub, unknowably_false)),
          Expr(:gotoifnot, Core.SSAValue(i), i+3),
          Expr(:call, Expr(:nooverdub, Core.SlotNumber(1)), (Core.SlotNumber(i) for i in 2:ref.method.nargs)...),
          x] : nothing)
    end
    CI.ssavaluetypes = length(CI.code)
    # Core.Compiler.validate_code(CI)
    return CI
end

const GPUifyPass = Cassette.@pass transform

Cassette.@context Ctx
const ctx = Cassette.disablehooks(Ctx(pass = GPUifyPass))

###
# Cassette fixes
###
Cassette.overdub(::Ctx, ::typeof(Core.kwfunc), f) = return Core.kwfunc(f)

# the functions below are marked `@pure` and by rewritting them we hide that from
# inference so we leave them alone (see https://github.com/jrevels/Cassette.jl/issues/108).
@inline Cassette.overdub(::Ctx, ::typeof(Base.isimmutable), x) = return Base.isimmutable(x)
@inline Cassette.overdub(::Ctx, ::typeof(Base.isstructtype), t) = return Base.isstructtype(t)
@inline Cassette.overdub(::Ctx, ::typeof(Base.isprimitivetype), t) = return Base.isprimitivetype(t)
@inline Cassette.overdub(::Ctx, ::typeof(Base.isbitstype), t) = return Base.isbitstype(t)
@inline Cassette.overdub(::Ctx, ::typeof(Base.isbits), x) = return Base.isbits(x)

@init @require CUDAnative="be33ccc6-a3ff-5ff2-a52e-74243cff1e17" begin
    using .CUDAnative
    @inline Cassette.overdub(::Ctx, ::typeof(CUDAnative.datatype_align), ::Type{T}) where {T} = CUDAnative.datatype_align(T)
end

###
# Rewrite functions
###

# define +, -, * as contract

for (f, T) in Base.Iterators.product((:add, :mul, :sub), (Float32, Float64))
    name = Symbol("$(f)_float_contract")
    if T === Float32
        llvmt = "float"
    elseif T === Float64
        llvmt = "double"
    end

    #XXX Use LLVM.jl
    ir = """
        %x = f$f contract $llvmt %0, %1
        ret $llvmt %x
    """
    @eval begin
        # the @pure is necessary so that we can constant propagate.
        Base.@pure function $name(a::$T, b::$T)
            @Base._inline_meta
            Base.llvmcall($ir, $T, Tuple{$T, $T}, a, b)
        end
    end
end
@inline Cassette.overdub(ctx::Ctx, ::typeof(+), a::T, b::T) where T<:Union{Float32, Float64} = add_float_contract(a, b)
@inline Cassette.overdub(ctx::Ctx, ::typeof(-), a::T, b::T) where T<:Union{Float32, Float64} = sub_float_contract(a, b)
@inline Cassette.overdub(ctx::Ctx, ::typeof(*), a::T, b::T) where T<:Union{Float32, Float64} = mul_float_contract(a, b)

# libdevice.jl
const cudafuns = (:cos, :cospi, :sin, :sinpi, :tan,
          :acos, :asin, :atan,
          :cosh, :sinh, :tanh,
          :acosh, :asinh, :atanh,
          :log, :log10, :log1p, :log2,
          :exp, :exp2, :exp10, :expm1, :ldexp,
          :isfinite, :isinf, :isnan,
          :signbit, :abs,
          :sqrt, :cbrt,
          :ceil, :floor,)
for f in cudafuns
    @eval function Cassette.overdub(ctx::Ctx, ::typeof(Base.$f), x::Union{Float32, Float64})
        @Base._inline_meta
        return CUDAnative.$f(x)
    end
end

"""
    contextualize(::Dev, f)

This contexualizes the function `f` for a given device type `Dev`.

For the device `CUDA()`, `contextualize` replaces calls to math library
functions.  For example, `cos`, `sin`, are replaced with `CUDAnative.cos`,
`CUDAnative.sin`, respectively.

The full list functions that are replaced is $cudafuns.

# Examples
```julia
function kernel!(::Dev, A, f) where {Dev}
    @setup Dev
    @loop for i in (1:size(A,1); threadIdx().x)
        A[i] = f(A[i])
    end
end

g(x) = sin(x)
kernel!(A::Array) = kernel!(CPU(), A, contextualize(CPU(), g))
kernel!(A::CuArray) =
    @cuda threads=length(A) kernel!(CUDA(), A, contextualize(CUDA(), g))

a = rand(Float32, 1024)
b, c = copy(a), CuArray(a)

kernel!(b)
kernel!(c)

@assert g.(a) ≈ b
@assert g.(a) ≈ c
```
"""
contextualize(f::F) where F = (args...) -> Cassette.overdub(ctx, f, args...)
