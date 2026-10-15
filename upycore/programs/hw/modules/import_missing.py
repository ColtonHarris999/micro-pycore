try:
    import no_such_mod_xyz
except ImportError as exc:
    print(type(exc).__name__, exc)
