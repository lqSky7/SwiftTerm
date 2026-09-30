/**
 * The SwiftTerm mark.
 *
 * Deliberately monochrome: every path inherits `currentColor`, so the mark can never introduce a
 * colour of its own and matches the achromatic token set the rest of the interface uses. There is
 * no accent fill here, and adding one would be the only saturated pixel in the product.
 *
 * The shape is a prompt: an angled chevron and a cursor block inside a rounded frame — the two
 * things a terminal is actually made of.
 */
export function Logo({ className }: { className?: string }) {
  return (
    <span className={className}>
      <svg
        width="108"
        height="32"
        viewBox="0 0 108 32"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
        className="h-7 w-auto"
      >
        {/* Frame */}
        <rect
          x="1.25"
          y="4.25"
          width="23.5"
          height="23.5"
          rx="6"
          stroke="currentColor"
          strokeWidth="1.5"
          opacity="0.35"
        />
        {/* Prompt chevron */}
        <path
          d="M7.5 12.5L11 16L7.5 19.5"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        {/* Cursor block */}
        <rect x="13.5" y="17.75" width="6.5" height="1.75" rx="0.875" fill="currentColor" />

        {/* Wordmark */}
        <text
          x="33"
          y="21.5"
          fontFamily="var(--font-geist-sans), ui-sans-serif, system-ui, sans-serif"
          fontSize="15"
          fontWeight="500"
          letterSpacing="-0.02em"
          fill="currentColor"
        >
          swiftterm
        </text>
      </svg>
    </span>
  );
}
