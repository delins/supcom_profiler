from dataclasses import dataclass, field


@dataclass(frozen=True)
class Func:
    source: str
    lineno: int
    name: str
    return_line: int

    def identifier(self, include_current_line: bool):
        if self.source == "=[C]":
            return self.name
        else:
            ident = f"{self.source}:{self.lineno}"
            if self.name:
                ident += f"({self.name})"
            if include_current_line:
                ident += f"->{self.return_line}"
            return ident


@dataclass
class CallStack:
    funcs: list[Func] = field(default_factory=list)
    count: int = 0
    total_duration: float = 0
    self_duration: float = 0.0


class _LoudLog:
    def __init__(self, path):
        self.path = path
        self._prefix = None
        self._sep = None

    def parse(self) -> list[CallStack]:
        call_stacks = []

        with open(self.path) as f:
            data = f.read()
            self._find_shared_path(data)
            f.seek(0)

            for line in f:
                if line.startswith("info: prof: "):
                    line = line.removeprefix("info: prof: ").rstrip()
                    stack = self._parse_stacktrace(line)
                    call_stacks.append(stack)

        return call_stacks

    def _parse_stacktrace(self, line: str) -> CallStack:
        parts = line.split(";")
        if len(parts) < 2:
            raise ValueError(f"Invalid profiler result: {line}")

        metrics = parts[-1]
        trace_funcs = parts[:-1]
        funcs = [self._parse_func(func) for func in trace_funcs]

        metrics_parts = metrics.split(",")
        count = int(metrics_parts[0])
        total_duration = float(metrics_parts[1])

        return CallStack(
            funcs,
            count,
            total_duration
        )

    def _parse_func(self, func_str) -> Func:
        parts = func_str.split(",")
        source = parts[0].replace(self._prefix, "").replace(self._sep, "/")
        return Func(source, int(parts[1]), parts[2], int(parts[3]))

    def _find_shared_path(self, data: str):
        """Find leading path to the lua files.

        A typical loud installation is in
            "C:\\program files (x86)\\steam\\steamapps\\common\\supreme commander forged alliance\\LOUD."

        So the profiler stores eg:
            "@c:\\program files (x86)\\steam\\steamapps\\common\\supreme commander forged alliance\\LOUD\\gamedata\\lua\\lua\\siminit.lua"

        which makes for a messy output. We find the common prefix
            "@c:\\program files (x86)\\steam\\steamapps\\common\\supreme commander forged alliance"

        :param data: the full loud log file
        :return: the common prefix
        """
        simit_init_path = data.find("\\gamedata\\lua\\lua\\siminit.lua")
        if simit_init_path != -1:
            self._sep = "\\"
        else:
            simit_init_path = data.find("/gamedata/lua/lua/siminit.lua")
            if simit_init_path != -1:
                self._sep = "/"

        if not self._sep:
            raise ValueError("Unable to detect Supreme Command Forged Alliance installation path. Does the file contain profiler data?")

        parent = data.rfind(self._sep, max(simit_init_path - 100, 0), simit_init_path)
        source = data.rfind("@", max(parent - 1000, 0), parent)
        self._prefix = data[source: parent]


def parse_loud_log(path: str) -> list[CallStack]:
    log = _LoudLog(path)
    return log.parse()

