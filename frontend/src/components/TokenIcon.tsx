/**
 * Lightweight, dependency-free token badge: a gradient circle with a glyph.
 * New tokens fall back to their first letter + a neutral gradient, so the UI
 * keeps working as more markets are added without bundling image assets.
 */
const TOKEN_STYLES: Record<string, { gradient: string; glyph: string }> = {
  mUSDC: { gradient: "from-sky-400 to-blue-600", glyph: "$" },
  mWETH: { gradient: "from-violet-400 to-indigo-600", glyph: "Ξ" },
  mWBTC: { gradient: "from-amber-400 to-orange-600", glyph: "₿" },
  mUSDT: { gradient: "from-teal-400 to-emerald-600", glyph: "₮" },
  mDAI: { gradient: "from-yellow-300 to-amber-500", glyph: "◈" },
  mLINK: { gradient: "from-blue-400 to-indigo-500", glyph: "⬡" },
};

export function TokenIcon({ symbol, size = 32 }: { symbol: string; size?: number }) {
  const style = TOKEN_STYLES[symbol] ?? {
    gradient: "from-slate-400 to-slate-600",
    glyph: symbol.replace(/^m/, "").charAt(0).toUpperCase() || "?",
  };

  return (
    <span
      aria-hidden
      className={`inline-flex shrink-0 items-center justify-center rounded-full bg-gradient-to-br ${style.gradient} font-bold text-white shadow-[0_2px_8px_-2px_rgba(0,0,0,0.6)] ring-1 ring-white/10`}
      style={{ width: size, height: size, fontSize: Math.round(size * 0.5) }}
    >
      {style.glyph}
    </span>
  );
}
