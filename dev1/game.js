const MIN_HAND_SIZE = 5;
const CARD_COST = 1;
const MAX_MANA = 10;
let cardCounter = 1;
let draggedCard = null;
let currentMana = MAX_MANA;

function addCard() {
    const cardArea = document.getElementById('cardArea');
    const cardData = getRandomCard();
    const card = document.createElement('div');
    card.className = 'card';
    card.innerHTML = `
        <span class="card-cost">${cardData.cost}</span>
        <span class="card-name">${cardData.name}</span>
        <span class="card-attack">${cardData.attack}</span>
        <span class="card-health">${cardData.health}</span>
    `;
    card.dataset.cardId = cardCounter;
    card.dataset.cost = cardData.cost;
    card.dataset.health = cardData.health;
    card.dataset.attack = cardData.attack;
    card.dataset.type = cardData.type;
    cardCounter++;
    
    card.addEventListener('dragstart', dragStart);
    card.addEventListener('dragend', dragEnd);
    card.draggable = true;
    
    cardArea.appendChild(card);
}

function ensureMinHandSize() {
    const cardArea = document.getElementById('cardArea');
    const currentCount = cardArea.children.length;
    for (let i = currentCount; i < MIN_HAND_SIZE; i++) {
        addCard();
    }
}

function updateManaDisplay() {
    document.getElementById('indicatorPanel').textContent = currentMana;
}

function dragStart(e) {
    const cardCost = parseInt(e.target.dataset.cost);
    if (currentMana < cardCost) {
        e.preventDefault();
        return;
    }
    draggedCard = e.target;
    e.target.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
}

function dragEnd(e) {
    e.target.classList.remove('dragging');
    draggedCard = null;
    document.querySelectorAll('.cell').forEach(cell => {
        cell.classList.remove('drop-target');
        cell.style.cursor = '';
    });
}

function dragOver(e) {
    e.preventDefault();
    
    if (draggedCard) {
        const cardType = draggedCard.dataset.type;
        const targetRow = parseInt(e.target.dataset.row);
        
        if (cardType === "单位" && targetRow >= 0 && targetRow <= 2) {
            e.dataTransfer.dropEffect = 'none';
            e.dataTransfer.effectAllowed = 'none';
            e.target.style.cursor = 'not-allowed';
            return;
        }
    }
    
    e.target.classList.add('drop-target');
}

function dragLeave(e) {
    e.target.classList.remove('drop-target');
    e.target.style.cursor = '';
}

function drop(e) {
    e.preventDefault();
    e.target.classList.remove('drop-target');
    e.target.style.cursor = '';
    
    if (draggedCard) {
        const cardType = draggedCard.dataset.type;
        const targetRow = parseInt(e.target.dataset.row);
        
        if (cardType === "单位" && targetRow >= 0 && targetRow <= 2) {
            return;
        }
        
        const cardCost = parseInt(draggedCard.dataset.cost);
        const cardAttack = parseInt(draggedCard.dataset.attack);
        const cardHealth = parseInt(draggedCard.dataset.health);
        if (currentMana >= cardCost) {
            currentMana -= cardCost;
            updateManaDisplay();
            e.target.innerHTML = `
                <span class="cell-text">${draggedCard.querySelector('.card-name').textContent}</span>
                <span class="cell-attack">${cardAttack}</span>
                <span class="cell-health">${cardHealth}</span>
            `;
            e.target.dataset.attack = cardAttack;
            e.target.dataset.health = cardHealth;
            e.target.classList.add('has-card');
            draggedCard.remove();
            ensureMinHandSize();
        }
    }
}

function lerp(start, end, t) {
    return start + (end - start) * t;
}

function createMovingCard(cellText, width, height, isEnemy = false) {
    const card = document.createElement('div');
    
    const style = card.style;
    style.position = 'fixed';
    style.width = width + 'px';
    style.height = height + 'px';
    style.minWidth = width + 'px';
    style.maxWidth = width + 'px';
    style.minHeight = height + 'px';
    style.maxHeight = height + 'px';
    style.boxSizing = 'border-box';
    style.overflow = 'hidden';
    style.background = isEnemy ? '#999' : '#fff';
    style.border = '2px solid #333';
    style.borderRadius = '4px';
    style.display = 'flex';
    style.justifyContent = 'center';
    style.alignItems = 'flex-start';
    style.paddingTop = Math.floor(height * 0.08) + 'px';
    style.fontSize = '12px';
    style.fontWeight = 'bold';
    style.fontFamily = 'sans-serif';
    style.color = '#333';
    style.lineHeight = '1.2';
    style.textAlign = 'center';
    style.wordBreak = 'break-word';
    style.whiteSpace = 'normal';
    style.zIndex = '1000';
    style.boxShadow = '0 2px 4px rgba(0,0,0,0.2)';
    style.margin = '0';
    
    card.textContent = cellText;
    
    return card;
}

function applyDamageEffect(element, originalBgColor) {
    element.classList.add('attacking');
    setTimeout(() => {
        element.classList.remove('attacking');
        element.classList.add('attacked');
        setTimeout(() => {
            element.classList.remove('attacked');
        }, 500);
    }, 200);
}

function applyAttackEffect(cell) {
    applyDamageEffect(cell);
}

function damageHero(isEnemy, damage) {
    if (isEnemy) {
        const enemyHealthEl = document.getElementById('enemyHealth');
        let enemyHealth = parseInt(document.getElementById('enemyHealthValue').textContent);
        enemyHealth -= damage;
        document.getElementById('enemyHealthValue').textContent = enemyHealth;
        applyDamageEffect(enemyHealthEl);
    } else {
        const playerHealthEl = document.getElementById('playerHealth');
        let playerHealth = parseInt(document.getElementById('playerHealthValue').textContent);
        playerHealth -= damage;
        document.getElementById('playerHealthValue').textContent = playerHealth;
        applyDamageEffect(playerHealthEl);
    }
}

function attackCell(attackerCell, defenderCell) {
    const attackerAttack = parseInt(attackerCell.dataset.attack);
    const defenderAttack = parseInt(defenderCell.dataset.attack);
    const attackerHealth = parseInt(attackerCell.dataset.health);
    const defenderHealth = parseInt(defenderCell.dataset.health);
    
    const newAttackerHealth = attackerHealth - defenderAttack;
    const newDefenderHealth = defenderHealth - attackerAttack;
    
    attackerCell.dataset.health = newAttackerHealth;
    defenderCell.dataset.health = newDefenderHealth;
    
    applyAttackEffect(attackerCell);
    applyAttackEffect(defenderCell);
    
    const attackerAttackEl = attackerCell.querySelector('.cell-attack');
    const attackerHealthEl = attackerCell.querySelector('.cell-health');
    const defenderAttackEl = defenderCell.querySelector('.cell-attack');
    const defenderHealthEl = defenderCell.querySelector('.cell-health');
    
    if (attackerHealthEl) {
        attackerHealthEl.textContent = newAttackerHealth;
    }
    if (defenderHealthEl) {
        defenderHealthEl.textContent = newDefenderHealth;
    }
    
    return { attackerDead: newAttackerHealth <= 0, defenderDead: newDefenderHealth <= 0 };
}

function findAdjacentEnemy(cell, isEnemy) {
    const row = parseInt(cell.dataset.row);
    const col = parseInt(cell.dataset.col);
    const enemyFlag = isEnemy ? "true" : "false";
    const playerFlag = isEnemy ? "true" : "false";
    
    let checkOrder;
    if (isEnemy) {
        checkOrder = [
            { r: row + 1, c: col },
            { r: row, c: col - 1 },
            { r: row, c: col + 1 },
            { r: row - 1, c: col }
        ];
    } else {
        checkOrder = [
            { r: row - 1, c: col },
            { r: row, c: col - 1 },
            { r: row, c: col + 1 },
            { r: row + 1, c: col }
        ];
    }
    
    for (const pos of checkOrder) {
        if (pos.r >= 0 && pos.r <= 5 && pos.c >= 0 && pos.c <= 2) {
            const targetCell = document.querySelector(`.cell[data-row="${pos.r}"][data-col="${pos.c}"]`);
            if (targetCell && targetCell.textContent.trim()) {
                const targetIsEnemy = targetCell.dataset.isEnemy === "true";
                if (isEnemy && targetIsEnemy === false) {
                    return targetCell;
                } else if (!isEnemy && targetIsEnemy === true) {
                    return targetCell;
                }
            }
        }
    }
    return null;
}

function animateCardMove(card, startRow, startCol, endRow, endCol, duration = 500) {
    return new Promise((resolve) => {
        const startCell = document.querySelector(`.cell[data-row="${startRow}"][data-col="${startCol}"]`);
        const endCell = document.querySelector(`.cell[data-row="${endRow}"][data-col="${endCol}"]`);
        
        if (!startCell || !endCell) {
            resolve();
            return;
        }
        
        const startRect = startCell.getBoundingClientRect();
        const endRect = endCell.getBoundingClientRect();
        
        const cardText = startCell.querySelector('.cell-text').textContent;
        const cardAttack = startCell.dataset.attack;
        const cardHealth = startCell.dataset.health;
        const isEnemy = startCell.dataset.isEnemy;
        const movingCard = createMovingCard(cardText, startRect.width, startRect.height, isEnemy === "true");
        
        movingCard.style.left = startRect.left + 'px';
        movingCard.style.top = startRect.top + 'px';
        
        document.body.appendChild(movingCard);
        
        startCell.innerHTML = '';
        startCell.classList.remove('has-card');
        delete startCell.dataset.attack;
        delete startCell.dataset.health;
        delete startCell.dataset.isEnemy;
        startCell.classList.remove('enemy-card');
        
        const startTime = performance.now();
        
        function animate(currentTime) {
            const elapsed = currentTime - startTime;
            const t = Math.min(elapsed / duration, 1);
            
            const currentX = lerp(startRect.left, endRect.left, t);
            const currentY = lerp(startRect.top, endRect.top, t);
            
            movingCard.style.left = currentX + 'px';
            movingCard.style.top = currentY + 'px';
            
            if (t < 1) {
                requestAnimationFrame(animate);
            } else {
                endCell.innerHTML = `
                    <span class="cell-text">${cardText}</span>
                    <span class="cell-attack">${cardAttack}</span>
                    <span class="cell-health">${cardHealth}</span>
                `;
                endCell.dataset.attack = cardAttack;
                endCell.dataset.health = cardHealth;
                endCell.classList.add('has-card');
                if (isEnemy === "true") {
                    endCell.dataset.isEnemy = "true";
                    endCell.classList.add('enemy-card');
                }
                movingCard.remove();
                resolve();
            }
        }
        
        requestAnimationFrame(animate);
    });
}

async function endTurn() {
    const endTurnBtn = document.getElementById('endTurnBtn');
    endTurnBtn.disabled = true;
    endTurnBtn.textContent = '行动中...';
    endTurnBtn.style.background = '#999';
    endTurnBtn.style.cursor = 'not-allowed';
    
    currentMana = MAX_MANA;
    updateManaDisplay();
    
    for (let row = 0; row <= 5; row++) {
        for (let col = 0; col <= 2; col++) {
            const cell = document.querySelector(`.cell[data-row="${row}"][data-col="${col}"]`);
            if (cell && cell.textContent.trim() && cell.dataset.isEnemy !== "true" && cell.dataset.hasAttacked !== "true") {
                const adjacentEnemy = findAdjacentEnemy(cell, false);
                if (adjacentEnemy) {
                    const result = attackCell(cell, adjacentEnemy);
                    cell.dataset.hasAttacked = "true";
                    if (result.defenderDead) {
                        adjacentEnemy.innerHTML = '';
                        adjacentEnemy.classList.remove('has-card', 'enemy-card');
                        delete adjacentEnemy.dataset.attack;
                        delete adjacentEnemy.dataset.health;
                        delete adjacentEnemy.dataset.isEnemy;
                    }
                    if (result.attackerDead) {
                        cell.innerHTML = '';
                        cell.classList.remove('has-card');
                        delete cell.dataset.attack;
                        delete cell.dataset.health;
                        delete cell.dataset.isEnemy;
                    }
                    await new Promise(r => setTimeout(r, 500));
                    continue;
                }
                
                if (row === 0) {
                    const attack = parseInt(cell.dataset.attack);
                    damageHero(true, attack);
                    cell.dataset.hasAttacked = "true";
                    await new Promise(r => setTimeout(r, 500));
                    continue;
                }
                
                const targetRow = row - 1;
                const targetCell = targetRow >= 0 ? document.querySelector(`.cell[data-row="${targetRow}"][data-col="${col}"]`) : null;
                
                const canMove = targetRow >= 0 && targetCell && !targetCell.textContent.trim();
                
                if (canMove) {
                    const card = document.createElement('div');
                    await animateCardMove(card, row, col, targetRow, col);
                    await new Promise(r => setTimeout(r, 500));
                }
            }
        }
    }
    
    for (let row = 5; row >= 0; row--) {
        for (let col = 2; col >= 0; col--) {
            const cell = document.querySelector(`.cell[data-row="${row}"][data-col="${col}"]`);
            if (cell && cell.textContent.trim() && cell.dataset.isEnemy === "true" && cell.dataset.hasAttacked !== "true") {
                const adjacentEnemy = findAdjacentEnemy(cell, true);
                if (adjacentEnemy) {
                    const result = attackCell(cell, adjacentEnemy);
                    cell.dataset.hasAttacked = "true";
                    if (result.defenderDead) {
                        adjacentEnemy.innerHTML = '';
                        adjacentEnemy.classList.remove('has-card');
                        delete adjacentEnemy.dataset.attack;
                        delete adjacentEnemy.dataset.health;
                        delete adjacentEnemy.dataset.isEnemy;
                    }
                    if (result.attackerDead) {
                        cell.innerHTML = '';
                        cell.classList.remove('has-card', 'enemy-card');
                        delete cell.dataset.attack;
                        delete cell.dataset.health;
                        delete cell.dataset.isEnemy;
                    }
                    await new Promise(r => setTimeout(r, 500));
                    continue;
                }
                
                if (row === 5) {
                    const attack = parseInt(cell.dataset.attack);
                    damageHero(false, attack);
                    cell.dataset.hasAttacked = "true";
                    await new Promise(r => setTimeout(r, 500));
                    continue;
                }
                
                const targetRow = row + 1;
                const targetCell = targetRow <= 5 ? document.querySelector(`.cell[data-row="${targetRow}"][data-col="${col}"]`) : null;
                
                const canMove = targetRow <= 5 && targetCell && !targetCell.textContent.trim();
                
                if (canMove) {
                    const card = document.createElement('div');
                    await animateCardMove(card, row, col, targetRow, col);
                    await new Promise(r => setTimeout(r, 500));
                }
            }
        }
    }
    
    document.querySelectorAll('.cell').forEach(cell => {
        delete cell.dataset.hasAttacked;
    });
    
    endTurnBtn.disabled = false;
    endTurnBtn.textContent = '结束回合';
    endTurnBtn.style.background = '';
    endTurnBtn.style.cursor = '';
}

document.addEventListener('DOMContentLoaded', () => {
    document.getElementById('playerHealthValue').textContent = playerConfig.playerHealth;
    document.getElementById('enemyHealthValue').textContent = playerConfig.enemyHealth;
    updateManaDisplay();
    initUnits();
    
    document.querySelectorAll('.cell').forEach(cell => {
        cell.addEventListener('dragover', dragOver);
        cell.addEventListener('dragleave', dragLeave);
        cell.addEventListener('drop', drop);
    });
    
    document.getElementById('endTurnBtn').addEventListener('click', endTurn);
    
    ensureMinHandSize();
});
