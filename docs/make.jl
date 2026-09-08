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

if get(ENV, "CI", nothing) == "true"
    deploydocs(
        repo = "github.com/GaetanHerold/BioprocessHardware.jl.git",
        devbranch = "main"
    )
end
