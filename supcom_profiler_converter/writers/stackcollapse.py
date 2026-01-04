from supcom_profiler_converter.core.process import Function


def write_stack_collapse(functions: list[Function], path: str):
    """Writes the function list out into the stack format.

    It adds an extra layer for each function call, which shows on what line a call was made. So if A calls B on line 10,
    and C on line 11, the output will be (schematically):
      A > A(10) > B.
      A > A(11) > C.
    """
    with open(path, 'w') as f:
        for function in functions:
            _write(function, "", f)

def _write(function: Function, prefix, f):
    line = f"{prefix}{function.identifier()}"
    print(f"{line} {int(function.self_duration() * 1000)}", file=f)

    for currentline_key, child_dict in function.children.items():
        for child in child_dict.values():
            _write(child, f"{line};{currentline_key};", f)

