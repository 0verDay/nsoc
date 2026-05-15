const testCards = [
    {
        name: "blanket",
        type: "单位",
        cost: 1,
        health: 1,
        attack: 1
    },
    {
        name: "pro",
        type: "单位",
        cost: 2,
        health: 2,
        attack: 2
    }
];

function getRandomCard() {
    const randomIndex = Math.floor(Math.random() * testCards.length);
    return testCards[randomIndex];
}
