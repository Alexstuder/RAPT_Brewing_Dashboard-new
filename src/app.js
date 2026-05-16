const API_BASE = '/api'; // via api_proxy

async function fetchRAPTData() {
  try {
    const res = await fetch(`${API_BASE}/rapt/latest`);
    const data = await res.json();
    document.getElementById('temp').textContent = `Temperatur: ${data.temperature}°C`;
    document.getElementById('gravity').textContent = `Gravity: ${data.gravity} SG`;
    document.getElementById('abv').textContent = `ABV: ${data.abv}%`;
  } catch (e) {
    console.error('RAPT Daten konnten nicht geladen werden:', e);
  }
}

fetchRAPTData();
setInterval(fetchRAPTData, 30000); // alle 30 Sekunden aktualisieren
