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
        ink: "#1e1e1e",
        accent: "#1743ff",
        line: "#cecece",
        control: "#949494",
        muted: "#5f5f5f",
        hover: "#f5f5f5",
        panel: "#ebebeb",
        wash: "#f6f6f6",
        disabled: "#bdbdbd",
        up: "#0b7d4f",
        "up-hover": "#096a43",
        down: "#c0263a",
        "down-hover": "#a11f31",
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
