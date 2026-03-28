/** @type {import('tailwindcss').Config} */
module.exports = {
  darkMode: 'class',
  content: [
    "./src/http_ui.zig",
    "./ui/templates/**/*.html",
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}
