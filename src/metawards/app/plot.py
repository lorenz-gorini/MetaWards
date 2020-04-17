
def parse_args():
    """Parse all of the command line arguments"""
    import argparse
    import sys

    parser = argparse.ArgumentParser(
                    description="MetaWards simple plotting program - see "
                                "https://github.com/metawards/metawards "
                                "for more information",
                    prog="metawards-plot")

    parser.add_argument('--version', action="store_true",
                        default=None,
                        help="Print the version information about "
                             "metawards-plot")

    parser.add_argument("-i", "--input", type=str,
                        help="Full path to the 'results.csv.bz2' file "
                             "that you want to quickly plot.")

    parser.add_argument("-a", "--animate", type=str, nargs="*",
                        help="Full path to the set of plots that you "
                             "want to animate together into an animated "
                             "gif")

    parser.add_argument("-o", "--output", type=str, default=None,
                        help="Location for the output. By default "
                             "this is inferred from the input")

    parser.add_argument("--format", type=str, default="pdf",
                        help="Desired format of the graphs that are "
                             "produced. Good formats are 'pdf' for "
                             "publication graphics and 'png' or 'jpeg' "
                             "for webpages")

    parser.add_argument("--delay", type=int, default=500,
                        help="The delay in milliseconds between animation "
                             "frames if an animation is being produced")

    parser.add_argument("--ordering", type=str, default="fingerprint",
                        help="Ordering to use for the frames. This "
                             "can be fingerprint, filename or custom")

    args = parser.parse_args()

    if args.version:
        from metawards import get_version_string
        print(get_version_string())
        sys.exit(0)

    return (args, parser)


def cli():
    """Main function for the metawards-plot command line interface.
       This is a simple program that creates basic plots of the output
       data. The aim is to make visualisation of the data as quick
       and painless as possible.
    """
    args, parser = parse_args()

    if args.input:
        from metawards.analysis import save_summary_plots

        filenames = save_summary_plots(results=args.input,
                                       output_dir=args.output,
                                       format=args.format,
                                       verbose=True)

        print(f"Written graphs to {', '.join(filenames)}")

    elif args.animate is not None and len(args.animate) > 0:
        from metawards.analysis import animate_plots

        filename = animate_plots(plots=args.animate,
                                 output=args.output,
                                 delay=args.delay,
                                 ordering=args.ordering,
                                 verbose=True)

        print(f"Written animation to {filename}")
    else:
        import sys
        parser.print_help()
        sys.exit(0)


if __name__ == "__main__":
    cli()