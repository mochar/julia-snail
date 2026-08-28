module JuliaSnailLatexifyExt

import JuliaSnail
import LaTeXStrings: LaTeXString
using Latexify

function JuliaSnail.Multimedia.format(::JuliaSnail.Request, ::Union{MIME"text/plain", MIME"text/latex", Nothing}, str::LaTeXString)
    :latex, String(str), nothing
end

end
