// Passes address lookups from the canvass app to the US Census geocoder,
// which does not accept calls straight from a web page.
export default async (req) => {
  if (req.method !== "POST") return new Response("POST a CSV of up to 200 addresses", { status: 405 });
  const lines = (await req.text()).split("\n").filter(l => l.trim());
  if (!lines.length || lines.length > 200) return new Response("Send 1 to 200 addresses", { status: 400 });
  const fd = new FormData();
  fd.append("addressFile", new Blob([lines.join("\n") + "\n"], { type: "text/csv" }), "addresses.csv");
  fd.append("benchmark", "Public_AR_Current");
  try {
    const r = await fetch("https://geocoding.geo.census.gov/geocoder/locations/addressbatch", { method: "POST", body: fd });
    return new Response(await r.text(), { status: r.status, headers: { "Content-Type": "text/csv", "Cache-Control": "no-store" } });
  } catch (e) {
    return new Response("Address lookup unreachable: " + e.message, { status: 502 });
  }
};

export const config = { path: "/api/geocode" };
