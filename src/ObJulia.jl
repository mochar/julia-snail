# Org babel. Mostly copy-past from karthink/ob-julia

module ObJulia

import Base.display

### Sexp
# The heavy-lifting of converting types to elisp happens here

"`string()` wrapper which escapes unsupported characters:
- `|`s are replaced by `\\vert{}`
- newlines are replaced by ` `"
function stringify(text)
    # To my understanding, newline is not supported inside cells, so we drop it
    reduce(replace,
           ('|' => "\\vert{}", "\n" => " "),
           init=string(text))
end

# TODO: instead of converting to string, convert them to a Sexp type,
# so that we can modify it before converting to string
wrap(x) = string("(", stringify(x), ")")
wrap(t::Tuple) = lst(t)
lisp(i) = i
lisp(i::Number) = i
lisp(n::Nothing) = "nil"
lisp(s::AbstractString) = string("\"", reduce(replace, ('\\' => "\\\\", '"' => "\\\""), init=s), "\"")
lst(x) = wrap(join(lisp.(x), " "))
lst(s::AbstractString) = wrap(lisp(s))

sexp(t::Tuple) = lst(t)
# sexp(a::AbstractVector) = wrap(join(wrap.(lisp.(stringify.(a))), " "))
sexp(a::AbstractVector) = wrap(join(lisp.(a), " "))
sexp(a::AbstractMatrix) =
    wrap(join([wrap(join(ObJulia.lisp.(ObJulia.stringify.(r)), " "))
               for r in eachrow(a)], " "))
sexp(s::StepRange) = wrap(join(wrap.(s), " "))
sexp(nt::NamedTuple) = wrap(join([wrap((k, nt[k])) for k in keys(nt)], " ")) 
sexp(a::Any) = "\"WARNING: Type $(typeof(a)) cannot be converted to sexp by ob-julia.\""

### Display

"Return a function which takes two arguments, the display and the
content to write to.  That function writes the content to the display,
prepended by the type `t`."
function write_type(t)
    "Writes `t` followed by content to `d`."
    function wrt(d::ObJuliaDisplay, content="")
        println(d.io, t)
        write(d.io, content)
    end
    return wrt
end
raw = write_type("raw")
table = write_type("table")
matrix = write_type("matrix")
verbatim = write_type("verbatim")
list = write_type("list")

struct ObJuliaDisplay <: AbstractDisplay
    io::IO
end

"""Display fallback for types we do not support."""
function display(d::ObJuliaDisplay, m, x; kwargs...)
    verbatim(d)
    show(d.io, x)
end

function display(d::ObJuliaDisplay, ::MIME"text/org", x; kwargs...)
    verbatim(d)
    show(d.io, MIME("text/plain"), x)
end

displayable(d::ObJuliaDisplay, M::MIME) = true

display(d::ObJuliaDisplay, x) = display(d, MIME("text/org"), x)

# Auto-Latexify

function display(d::ObJuliaDisplay, ::MIME"text/org+latexify", x; kwargs...)
    if !isdefined(Main, :Latexify)
        try
            @eval using Latexify
            OrgBabelReload()
        catch
            return display(d, MIME"text/org", "\"Error: Latexify is not installed. Run `import Pkg; Pkg.add(\\\"Latexify\\\")` to rectify.\"")
        end
    end
    try
        verbatim(d, Main.latexify(x))
    catch
        display(d, MIME("text/org"), x; kwargs...)
    end
end

# types it doesn't make sense to Latexify
function display(d::ObJuliaDisplay, ::MIME"text/org+latexify", x::T; kwargs...) where
    { T <: Union{Number, String} }
    display(d, MIME("text/org"), x; kwargs...)
end

### Display: Base

# Display functions for types defined in Julia base
display(d::ObJuliaDisplay, ::MIME"text/org", t::Tuple; kwargs...) =
        table(d, sexp(t))
display(d::ObJuliaDisplay, ::MIME"text/org", ::Nothing; kwargs...) =
    result_is_auto(kwargs) ? verbatim(d, "") : verbatim(d, "()")

display(d::ObJuliaDisplay, ::MIME"text/org", a::AbstractArray{T,1};
        kwargs...) where T <: Any = table(d, sexp(a))
display(d::ObJuliaDisplay, ::MIME"text/org", s::AbstractString;
        kwargs...) = verbatim(d, s)

function display(d::ObJuliaDisplay, ::MIME"text/html", i::AbstractArray{T,2};
                 kwargs...) where T <: Any
    width = param(:width, "100")(kwargs)
    verbatim(d)
    println(d.io, """<table style="width:$width%">""")
    content = string("<tr>\n",
                     join([string("<th>", join(l, "</th><th>"))
                           for l in eachrow(i)], "</tr><tr>\n"))
    print(d.io, content, "</table>")
end

display(d::ObJuliaDisplay, ::MIME"text/org", i::AbstractArray{T,2};
                 kwargs...) where T <: Any = table(d, sexp(i))

function display(d::ObJuliaDisplay, ::MIME"text/csv", i::AbstractArray{T,2};
                 kwargs...) where T <: Any
    out = eachrow(i) |> x -> join([join(l, ',') for l in x], '\n')
    write(d.io, out)
end

display(d::ObJuliaDisplay, ::MIME"text/org", t::NamedTuple; kwargs...) =
    table(d, sexp(t))

"""Format a vector of named tuple as a table."""
function display(d::ObJuliaDisplay, ::MIME"text/org", nt::Vector{<:NamedTuple};
                 kwargs...)
    length(nt) == 0 && return table(d, "")
    # This assume keys are the same.
    # check that all the keys are equal
    if length(nt) > 1 && length(unique([keys(x) for x in nt])) == 1
        # Format as a table
        table(d, "(")
        print(d.io, lst(keys(first(nt))))
        for t in nt
            print(d.io, lst(values(t)))
            println(d.io)
        end
        print(d.io, ")")
    else
        table(d, "(")
        for t in nt
            ks = keys(t)
            print(d.io, lst(Iterators.flatten([(k, t[k]) for k in ks])))
        end
        print(d.io, ")")
    end
end

function display(d::ObJuliaDisplay, ::MIME"text/org", a::AbstractDict; kwargs...)
    table(d, wrap(join(wrap.(reverse(join.([[lisp(stringify(k)), lisp(stringify(v))] for (k, v) in a], " "))), " ")))
end

### Display: Stdlib

# Display function for types defined in Julia standard library
using Dates

fmt(date::Date) = Dates.format(date, "yyyy-mm-dd e")
fmt(date::DateTime) = Dates.format(date, "yyyy-mm-dd e HH:MM")

inactive(d) = string("[", fmt(d), "]")
inactive(d::String) = string("[", d, "]")

stringify(d::Union{Date,DateTime}) = inactive(d)

display(d::ObJuliaDisplay, ::MIME"text/org", i::T;
        kwargs...) where T <: Union{Date,DateTime} =
    verbatim(d, inactive(i))

# days (d), weeks (w), months (m), or years (y)
unit(x::Day) = "d"; unit(x::Week) = "w"; unit(x::Month) = "m"; unit(x::Year) = "y";

### Display: Packages

# External packages support
# To add support for new packages:
# 1. Add the package name as a Symbol in the supported_packages array
# 2. Add a define_$pkg function
# 3. That function should @eval the required display() functions
# 4. Test it

"""List of symbols of package names supported by ob-julia.

Packages already included in a session get removed from this list."""
const supported_packages = [
    :LinearAlgebra,
    :DataFrames,
    :Latexify, :LaTeXStrings,
    :Gadfly, :Plots, :Makie, :CairoMakie, :GLMakie, :WGLMakie]

"""
Map package symbol to mime types it can produce.

This is used to determine the mime type from the evaluation result.
"""
const package_mimes = Dict(
    :Plots => MIME.(["image/gif",
                     "image/png",
                     "image/svg+xml",
                     "application/pdf",
                     "application/postscript",
                     "image/eps",
                     "application/x-tex",
                     "text/html"]),
    :GadFly => MIME.(["application/postscript",
                      "application/pdf",
                      "image/png",
                      "image/svg+xml"]),
    :Makie => MIME.(["image/png",
                     "image/svg+xml",
                     "application/pdf",
                     "application/postscript",
                     "image/eps",
                     "text/html"]),
    :GLMakie => MIME.(["image/png"]),
    :WGLMakie => MIME.(["text/html"])
)

"Call define_\$pkg function."
define_package_functions(pkg::Symbol) = (@eval $pkg)()

"Defines show methods based on packages loaded by the user in the
current session."
function OrgBabelReload()
    for pkg in supported_packages
        if isdefined(Main, pkg) && (isa(getfield(Main, pkg), Module) ||
                                    isa(getfield(Main, pkg), UnionAll))
            define_package_functions(Symbol("define_", pkg))
            # Remove loaded packages from list to prevent multiple execution
            filter!(x -> x != pkg, supported_packages)
        end
    end
end

function define_LinearAlgebra()
    @eval sexp(a::Main.LinearAlgebra.Adjoint{AbstractMatrix}) = sexp(collect(a))
    @eval sexp(a::Main.LinearAlgebra.Adjoint{AbstractVector}) = wrap(join(lisp.(stringify.(a)), " "))
end

function define_LaTeXStrings()
    @eval function display(d::ObJuliaDisplay, ::MIME"text/org",
                           l::Main.LaTeXString; kwargs...)
        verbatim(d, String(l))
    end
end

function define_Latexify()
    # Latexify outputs LaTeXStrings.LaTeXString objects, but
    # LaTeXStrings is not included into Main now.  That's why we have
    # to define this method here
    @eval function display(d::ObJuliaDisplay, ::MIME"text/org",
                           l::Main.Latexify.LaTeXStrings.LaTeXString; kwargs...)
        verbatim(d, String(l))
    end
    # We want to latexify anything we can if the output is a tex file
    @eval function display(d::ObJuliaDisplay, ::MIME"application/x-tex",
                           obj::Any; kwargs...)
        verbatim(d, Main.latexify(obj))
    end
end

function define_DataFrames()
    @eval function display(d::ObJuliaDisplay, ::MIME"text/csv",
                           df::Main.DataFrame; kwargs...)
        # text/org is just a csv which org parses automatically, so we
        # can fallback to it
        out = join(string.(names(df)), ',') * '\n'
        out *= join([join(x, ',') for x in eachrow(df) .|> collect],'\n')
        write(d.io, out)
    end
    @eval function display(d::ObJuliaDisplay, ::MIME"text/org",
                           df::Main.DataFrame; kwargs...)
        table(d, string("((", join(lisp.(names(df)), " "), ") hline ",
                        sexp(Matrix(df))[2:end]))
    end
    @eval function display(d::ObJuliaDisplay, ::MIME"text/org+latexify", df::Main.DataFrame; kwargs...)
        display(d, MIME("text/org"), df; kwargs...)
    end
end

function define_Gadfly()
    @eval interpretlength(_::Nothing, default) = default
    @eval interpretlength(length::Int, default) = length * Main.Gadfly.inch
    @eval function interpretlength(length::String, default)
        m = match(r"^([\d.]+)([a-z]+)$", length)
        units = Dict("mm" => Main.Gadfly.mm,
                     "cm" => Main.Gadfly.cm,
                     "pt" => Main.Gadfly.pt,
                     "px" => Main.Gadfly.px,
                     "in" => Main.Gadfly.inch,
                     "inch" => Main.Gadfly.inch)
        if ! isnothing(m)
            parse(Float64, m.captures[1]) * get(units, m.captures[2], Main.Gadfly.inch)
        else
            default
        end
    end
    @eval function display(d::ObJuliaDisplay, ::MIME"text/org",
                           p::Main.Gadfly.Plot; height=nothing, width=nothing, output_dir=nothing, file_ext=nothing, kwargs...)
        filename = string(tempname(if ! isnothing(output_dir) output_dir else tempdir() end),
                          if isnothing(file_ext) ".svg" else "." * file_ext end)
        width = interpretlength(width, √200*Main.Gadfly.cm)
        height = interpretlength(height, 10*Main.Gadfly.cm)
        Main.Gadfly.draw(Main.Gadfly.SVG(filename, width, height), p)
        verbatim(d, filename)
    end
    @eval function saveplot(d::ObJuliaDisplay, formatter, p::Main.Gadfly.Plot; height=nothing, width=nothing)
        width = interpretlength(width, √200*Main.Gadfly.cm)
        height = interpretlength(height, 10*Main.Gadfly.cm)
        Main.Gadfly.draw(formatter(d.io, width, height), p)
    end
    @eval display(d::ObJuliaDisplay, ::MIME"image/svg+xml", p::Main.Gadfly.Plot; height=nothing, width=nothing, kwargs...) =
        saveplot(d, Main.Gadfly.SVG, p; height, width)
    @eval display(d::ObJuliaDisplay, ::MIME"image/png", p::Main.Gadfly.Plot; height=nothing, width=nothing, kwargs...) =
        saveplot(d, Main.Gadfly.PNG, p; height, width)
    @eval display(d::ObJuliaDisplay, ::MIME"image/png", p::Main.Gadfly.Plot; height=nothing, width=nothing, kwargs...) =
        saveplot(d, Main.Gadfly.PNG, p; height, width)
    @eval display(d::ObJuliaDisplay, ::MIME"application/pdf", p::Main.Gadfly.Plot; height=nothing, width=nothing, kwargs...) =
        saveplot(d, Main.Gadfly.PDF, p; height, width)
    @eval display(d::ObJuliaDisplay, ::MIME"application/postscript", p::Main.Gadfly.Plot; height=nothing, width=nothing, kwargs...) =
        saveplot(d, Main.Gadfly.PS, p; height, width)
end

function define_Plots()
    @eval display(d::ObJuliaDisplay, mime::M, p::Main.Plots.Plot; kwargs...) where
    { M <: Union{MIME"image/png", MIME"image/svg+xml", MIME"application/pdf", MIME"application/postscript",
                 MIME"image/eps", MIME"application/x-tex", MIME"text/html", MIME"image/gif"}}=
                     show(d.io, mime, p)
    @eval display(d::ObJuliaDisplay, mime::MIME"text/org", p::Main.Plots.Plot; kwargs...) =
        (verbatim(d); show(d.io, MIME("text/plain"), p))
end


function define_Makie()
    # Support for standard Makie outputs (png, svg, pdf, etc.) for both Figure and FigureAxisPlot
    @eval display(d::ObJuliaDisplay, mime::M, p::Main.Makie.FigureAxisPlot; kwargs...) where
    { M <: Union{MIME"image/png", MIME"image/svg+xml", MIME"application/pdf", MIME"application/postscript",
                 MIME"image/eps", MIME"text/html"}}=
              show(d.io, mime, p)
                     
    @eval display(d::ObJuliaDisplay, mime::M, p::Main.Makie.Figure; kwargs...) where
    { M <: Union{MIME"image/png", MIME"image/svg+xml", MIME"application/pdf", MIME"application/postscript",
                 MIME"image/eps", MIME"text/html"}}=
              show(d.io, mime, p)

    # Fallback to org verbatim text if no graphical MIME is requested
    @eval display(d::ObJuliaDisplay, mime::MIME"text/org", p::Main.Makie.FigureAxisPlot; kwargs...) =
              (verbatim(d); show(d.io, MIME("text/plain"), p))
        
    @eval display(d::ObJuliaDisplay, mime::MIME"text/org", p::Main.Makie.Figure; kwargs...) =
              (verbatim(d); show(d.io, MIME("text/plain"), p))
end

function define_CairoMakie() define_Makie() end
function define_GLMakie() define_Makie() end
function define_WGLMakie() define_Makie() end

### Eval

# Simple params accessors with fallback for src block params
param(name, fallback) = p -> something(get(p, name, fallback), fallback)
pure_p = param(:pure, false)
working_dir = param(:dir, pwd())
result(p) = get(p, :results, "") |> split
result_is_output(p) = "output" in result(p)
result_is_raw(p) = "raw" in result(p)
result_is_matrix(p) = "matrix" in result(p)
result_is_table(p) = "table" in result(p)
result_is_list(p) = "list" in result(p)
result_is_auto(p) = all(.![result_is_raw(p),
                           result_is_list(p),
                           result_is_matrix(p),
                           result_is_table(p)])
file_name = param(:file, nothing)

"""
Map file extension to MIME. This is used to identify the file type.
"""
const MIMES = Dict(
    # keep those sorted :)
    ""     => MIME("text/org"),
    "csv"  => MIME("text/csv"),
    "eps"  => MIME("image/eps"),
    "html" => MIME("text/html"),
    "org"  => MIME("text/org"),
    "pdf"  => MIME("application/pdf"),
    "png"  => MIME("image/png"),
    "ps"   => MIME("application/postscript"),
    "svg"  => MIME("image/svg+xml"),
    "tex"  => MIME("application/x-tex"))

"""Remove from the stacktrace info about ob-julia, to have a cleaner
output."""
function drop_useless_trace(trace)
    idx = findfirst(f -> f.func == Symbol("top-level scope"), trace)
    trace[idx:end]
end

"""Evaluate code in input file `src`. Store stdout and stderr to
`output_stream` and return a tuple with the outcome of the evaluation
and its result. The boolean `catch_errors` determines if errors should
be safely handled and the stacktrace returned, in which case the
outcome is false. Directory during evaluation is chanded `dir`, which
defaults to the current directory.

TODO: The output will be printed to a display with mime type
`mime`."""
function org_eval(src, output_stream, dir=pwd(), catch_errors=true, mod_name="Main") #, mime=MIMES[""])
    # Resolve the target module in the latest world age
    target_mod = Base.invokelatest(getfield, Main, Symbol(mod_name))
    
    # Meta.parse parses only one expression, so we wrap the code in a
    # block.  It can either be a let block or a begin block.
    return cd(expanduser(dir)) do
        # TODO: support mime time on print calls?
        pushdisplay(ObJuliaDisplay(output_stream))
        cd(expanduser(dir)) do
            redirect_stdout(output_stream) do
                redirect_stderr(output_stream) do
                    try
                        (true, Base.include_string(target_mod, read(src, String)))
                    catch e
                        # There's an evaluation error, store it both
                        # as output and return as result
                        errbuf = IOBuffer()
                        showerror(errbuf, e)
                        err = String(take!(errbuf))
                        if catch_errors # Handle errors with ObJulia
                            (false, [err, drop_useless_trace(stacktrace())...])
                        else
                            rethrow()
                        end
                    finally
                        popdisplay()
                    end
                end
            end
        end
    end
end

"""Determine the output MIME type based on filename. Fallback to `fallback`."""
function output_mime(filename; fallback="")
    # ext might either be an empty string or an extension with a "."
    # prefix
    ext = splitext(filename)[end]
    get(MIMES, isempty(ext) ? fallback : ext[2:end], MIMES[fallback])
end

"""Determine the output MIME type based on file contents or filename. Fallback
to `fallback`."""
function output_mime(filename, result; fallback="")
    # ext might either be an empty string or an extension with a "."
    # prefix
    ext = splitext(filename)[end]
    # Remove the prefix if present, and return the correct mimetype.
    # If the the desired extension is not present in our MIMES dict,
    # fallback.
    mime = auto_determine_mime(result)
    if mime == nothing
        get(MIMES, isempty(ext) ? fallback : ext[2:end], MIMES[fallback])
    else
        mime
    end
end

"""
Determine mime type based on evaluation result.

This tests all mime types in `package_mimes` to see if the result can be
displayed by it. The first mime type that can is returned.
"""
function auto_determine_mime(result)
    for pkg in keys(package_mimes)
        if isdefined(Main, pkg) && (isa(getfield(Main, pkg), Module) ||
            isa(getfield(Main, pkg), UnionAll))
            # showable_mime_type =
            #     iterate(Iterators.filter(m -> showable(m, result),
            #                              package_mimes[pkg]))
            showable_mime_type =
                iterate(Iterators.filter(m -> Base.invokelatest(showable, m, result),
                                         package_mimes[pkg]))
            mime_type =
                if (showable_mime_type == nothing) nothing
                else showable_mime_type[1] end
            if mime_type != nothing
                return mime_type
            end
        end
    end
end

"""ob-julia entry point. Run the code contained in `src-file`. The
output is written to `output_file`, according to config options
defined in `params`.

If `catch_errors` is true (default), exceptions are handled by
ObJulia and the trace is included in a separate trace file.

If `print_output` is true (default), print the `async_uuid` instead of
returning it.

If `automime` is true, change the extension of the `output_file`
heuristically to a better suited one."""
function OrgBabelEval(src_file, output_file, params, async_uuid=nothing;
                      print_output=true, automime=false, catch_errors=true)
    "Return a temporary file in the same dir as `output`.
     Create the dir if it does not exists."
    function safe_mktemp(output)
        dir = dirname(output)
        mkpath(dir)
        mktemp(dir)
    end
    # Create a new output file where Julia will store its results in
    # the same dir where ob-julia expect its ouput file
    temporary_output, temporary_stream = safe_mktemp(output_file)
    
    # Parse the params (named tuple passed by ob-julia)
    params = Main.eval(Meta.parse(params))
    latexify = something(params[:latexify], "nil") != "nil"
    target_mod = params[:target_module] === nothing ? "Main" : string(params[:target_module])
    
    # If results is output, running the code will start writing data
    # directly on the output file.  That's ok, but we need to tell
    # ob-julia the way this data is formatted.  We have no idea, so
    # let's use raw.  We might use header arguments for things like
    # images
    if result_is_output(params)
        println(temporary_stream, "raw")
    end
    
    success, result = org_eval(src_file, temporary_stream, working_dir(params), catch_errors, target_mod)
    
    # Now the code has been executed and imports have been imported.
    # We can reload supported display function so maybe one of them will be used
    OrgBabelReload()
    if !success
        # Execution failed, write stacktrace file
        trace_file = string(output_file, ".trace")
        write(output_file, "")
        write(trace_file, join(result, "\n"))
    end
    if result_is_output(params)
        mime = output_mime(output_file)
        # Data has already been written to temporary_stream, close it
        # and move the file
        close(temporary_stream)
        # Write the result to the temporary file
        # replace the output file with the file in which we wrote our results
        mv(temporary_output, output_file, force=true)
    elseif result_is_raw(params) && (latexify == "nil")
        mime = output_mime(output_file)
        write(output_file, string("raw\n", result))
    else
        # We need to write the output results to the output file
        io = IOBuffer()
        # Since display function might get re-defined during the
        # execution of this function (because of OrgBabelReload) we
        # want to be sure to call the latest version
        mime = output_mime(output_file, result)
        Base.invokelatest(display, ObJuliaDisplay(io),
                          if mime == MIME("text/org") && latexify
                              MIME("text/org+latexify")
                          else mime end, result; params...)
        write(output_file, take!(io))
    end
    if async_uuid == nothing
        if print_output println("$(mime)") end
        return "$(mime)"
    else
        if print_output
            println("ob_julia_async_$(async_uuid)")
            println("$(mime)")
        end
        return "(\"ob_julia_async_$(async_uuid)\" . \"$(mime)\")"
    end
end

### Tail

end # module
