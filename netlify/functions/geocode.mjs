// Passes address lookups from the canvass app to the US Census geocoder,
// which does not accept calls straight from a web page.
// Only a signed-in, turned-on team member can use it: the app sends the person's
// Supabase sign-in token, and the database's is_member() check must say yes.

const SUPABASE_URL = process.env.SUPABASE_URL || "https://ypuvvryeoruclxobwzhl.supabase.co";
// The public (anon) key, the same one the web page already carries. It grants nothing by itself.
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ||
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlwdXZ2cnllb3J1Y2x4b2J3emhsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYwMzgyODMsImV4cCI6MjEwMTYxNDI4M30.WpeOJDKBvAijgU1zMyJ2ZmVVJnT8vcow-k0fHfk7cfs";

async function isTeamMember(req) {
  const auth = req.headers.get("authorization") || "";
  if (!/^Bearer\s+\S+/.test(auth)) return false;
  try {
    const r = await fetch(SUPABASE_URL + "/rest/v1/rpc/is_member", {
      method: "POST",
      headers: { "apikey": SUPABASE_ANON_KEY, "Authorization": auth, "Content-Type": "application/json" },
      body: "{}"
    });
    if (!r.ok) return false;
    return (await r.json()) === true;
  } catch (e) {
    return false;
  }
}

export default async (req) => {
  if (req.method !== "POST") return new Response("POST a CSV of up to 200 addresses", { status: 405 });
  if (!(await isTeamMember(req))) return new Response("Sign in to the canvass app to use address lookup", { status: 401 });
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
