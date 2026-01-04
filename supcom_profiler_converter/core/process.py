from dataclasses import dataclass, field
from .loud_log import CallStack


@dataclass()
class Function:
    source: str
    lineno: int
    name: str
    total_duration: float = 0.0
    children: dict = field(default_factory=dict)

    def identifier(self):
        if self.source == "=[C]":
            return self.name
        else:
            ident = f"{self.source}:{self.lineno}"
            if self.name:
                ident += f"({self.name})"
            return ident

    def self_duration(self) -> float:
        total_child_duration = 0.0
        for child_dict in self.children.values():
            for child in child_dict.values():
                total_child_duration += child.total_duration

        return self.total_duration - total_child_duration


def process(call_stacks: list[CallStack]) -> list[Function]:
    functions = {}

    for call_stack in call_stacks:
        function = _add(functions, call_stack, 0)
        for index in range(1, len(call_stack.funcs)):
            function = _add(function.children, call_stack, index)

    return list(functions.values())


def _add(children: dict, call_stack: CallStack, index: int) -> Function:
    """
    Observe this callgraph, starting from function A:

    A -> 1 -> B -> 10 -> P
              B -> 11 -> Q
              B -> 11 -> R
      -> 2 -> C
      -> 3 -> D -> 50 -> X
              E -> 100 -> Y

    A calls three functions: B, C and D and E, from lines 1, 2, 3 and 3 respectively.
    B calls function P from line 10, and both Q and R from line 11.
    C doesn't call
    D calls X from line 50
    E calls Y from line 100

    With every step, either function name (key) or line, a dictionary is involved.

    The lines correspond with Func's return_line (aka currentline from Lua's debug.getinfo)

    Total durations are taken from the call stack when the current index's func is the last in the call stack.
    Self durations aren't calculated here, but Functions can easily do that themselves once we're done.
    """

    func = call_stack.funcs[index]

    # Find the index where the children live. This is basically dictated by our parent's return line, under which we
    # should be placed. Only if we're at the root of the callstack we use our returnlineless identifier.
    if index == 0:
        designated_dict = children
    else:
        # We have to nest func into our parent's children dict

        returnline_key = call_stack.funcs[index - 1].identifier(True)

        # Get the dictionary based on the return_line key
        designated_dict = children.get(returnline_key)
        if not designated_dict:
            designated_dict = {}
            children[returnline_key] = designated_dict

    key = func.identifier(False)

    function = designated_dict.get(key)
    if not function:
        function = Function(
            func.source,
            func.lineno,
            func.name,
        )
        designated_dict[key] = function

    if index == len(call_stack.funcs) - 1:
        function.total_duration = call_stack.total_duration

    return function

