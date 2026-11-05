const b = document.querySelector('.menu'), l = document.getElementById('links');
b.addEventListener('click', () => b.setAttribute('aria-expanded', l.classList.toggle('open')));
