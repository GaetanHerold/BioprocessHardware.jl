using Documenter
using BioprocessHardware

ENV["GKSwstype"] = "100"

include(joinpath(@__DIR__, "src", "generate_plots.jl"))

makedocs(
    modules = [BioprocessHardware],
    authors = "Gaétan Herold <gaetan.herold@ugent.be>",
    sitename = "BioprocessHardware.jl",
    remotes = nothing,
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://gaetanherold.github.io/LUCRA/hardware/",
        assets = String["assets/custom.css"],
        mathengine = Documenter.MathJax3()
    ),
    pages = [
        "Home" => "index.md",
        "Hardware Protocols" => "hardware/protocols.md",
        "API Reference" => "api.md",
    ],
    warnonly = [:missing_docs, :cross_references]
)

# Mirror assets to all subdirectories in build so relative paths resolve at all URL depths
build_dir = joinpath(@__DIR__, "build")
assets_src = joinpath(build_dir, "assets")
if isdir(assets_src)
    for (root, dirs, files) in walkdir(build_dir)
        if root != build_dir && basename(root) != "assets" && !occursin("assets", root)
            target = joinpath(root, "assets")
            if !isdir(target)
                cp(assets_src, target; force=true)
            end
        end
    end
end

if get(ENV, "CI", nothing) == "true"
    deploydocs(
        repo = "github.com/GaetanHerold/BioprocessHardware.jl.git",
        devbranch = "main"
    )
end
