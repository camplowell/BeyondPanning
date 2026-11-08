from pathlib import Path

from cyclopts import App

main = App()

@main.command
def geo_only(data: Path):
    from encoder.blockhead import fit
    from encoder.sofa import Sofa
    result = fit(Sofa(data))
    print(f"Radius: {result.radius[0]:.4f} m\nBlock:  {result.block[0]:.4f} m")

@main.command
def devices():
    import jax
    print(jax.devices())
