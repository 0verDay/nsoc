const UNIT_CONFIG = [
    { name: "blanket", faction: 1, positions: [{ row: 0, col: 0 }, { row: 0, col: 1 }, { row: 0, col: 2 }] },
    { name: "blanket", faction: 0, positions: [{ row: 5, col: 1 }] }
];

function initUnits() {
    UNIT_CONFIG.forEach(config => {
        const cardData = testCards.find(card => card.name === config.name);
        if (!cardData) return;

        const isEnemy = config.faction === 1;

        config.positions.forEach(pos => {
            const cell = document.querySelector(`.cell[data-row="${pos.row}"][data-col="${pos.col}"]`);
            if (cell) {
                cell.innerHTML = `
                    <span class="cell-text">${cardData.name}</span>
                    <span class="cell-attack">${cardData.attack}</span>
                    <span class="cell-health">${cardData.health}</span>
                `;
                cell.dataset.attack = cardData.attack;
                cell.dataset.health = cardData.health;
                if (isEnemy) {
                    cell.dataset.isEnemy = "true";
                    cell.classList.add('enemy-card');
                }
                cell.classList.add('has-card');
            }
        });
    });
}
