module JuliaSnailMakieExt

import JuliaSnail
using Makie, Base64

const EXTS = Dict(
    "image/png" => "png",
    "image/svg+xml" => "svg",
)

function JuliaSnail.Multimedia.format(req::JuliaSnail.Request, mime, plot::Union{Makie.FigureLike, Makie.FigureAxisPlot})
    mime = mime === nothing ? "image/png" : string(mime)
    ext = get(EXTS, mime, nothing)
    ext === nothing && throw(MethodError(format, (req, mime, plot)))
    img_encoded = base64encode(show, mime, plot)
    :image, img_encoded, (ext=ext,)
end

end
