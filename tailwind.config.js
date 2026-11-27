/** Tailwind content sources for the Sweeft site.
 *
 * Theme: Meridian-style light editorial (ink on white, blue accent), fluid
 * serif display. The dark red identity is replaced; semantic up/down tones
 * keep status meaning. Fonts are system stacks only (self-hosted, CSP-safe).
 */
module.exports = {
  content: [
    "./templates/**/*.html",
    "./static/js/**/*.js",
    "./apps/**/*.py",
  ],
  theme: {
    extend: {
      colors: {
        ink: "#f5f5f5",
        accent: "#ff4d4d",
        line: "#2a2a2e",
        control: "#3a3a40",
        muted: "#a1a1aa",
        hover: "#17171a",
        panel: "#17171a",
        wash: "#17171a",
        disabled: "#52525b",
        up: "#34d399",
        "up-hover": "#10b981",
        down: "#f87171",
        "down-hover": "#ef4444",
      },
      fontFamily: {
        serif: ["'Instrument Serif'", "Georgia", "'Times New Roman'", "serif"],
        sans: ["'Instrument Sans'", "-apple-system", "BlinkMacSystemFont", "Segoe UI", "sans-serif"],
      },
      animation: {
        rise: "rise 900ms cubic-bezier(0.22,1,0.36,1) both",
        flash: "flash 700ms cubic-bezier(0.22,1,0.36,1)",
        pulse: "pulse 2s cubic-bezier(0.4,0,0.6,1) infinite",
      },
      keyframes: {
        rise: {
          from: { opacity: "0", transform: "translateY(14px)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
        flash: {
          from: { backgroundColor: "rgb(23 67 255 / 0.14)" },
          to: { backgroundColor: "transparent" },
        },
      },
    },
  },
  plugins: [],
};
