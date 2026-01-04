import argparse
from supcom_profiler_converter.core.loud_log import parse_loud_log
from supcom_profiler_converter.core.process import process
from supcom_profiler_converter.writers.stackcollapse import write_stack_collapse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-o', "--output", required=True)
    parser.add_argument("loud_log")
    args = parser.parse_args()

    call_stacks = parse_loud_log(args.loud_log)

    functions = process(call_stacks)
    write_stack_collapse(functions, args.output)


if __name__ == "__main__":
    main()

