function format(::Request, ::MIME"text/latex", str::AbstractString)
    :latex, str, nothing
end

function format(::Request, ::MIME"text/plain", x)
    :text, sprint(show, MIME("text/plain"), x), nothing
end
