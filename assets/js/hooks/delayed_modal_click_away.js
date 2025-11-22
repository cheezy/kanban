const DelayedModalClickAway = {
  mounted() {
    this.clickAwayHandler = null;
    
    setTimeout(() => {
      this.clickAwayHandler = (event) => {
        const container = this.el.querySelector('[data-modal-container]');
        if (!container) return;
        
        if (!container.contains(event.target)) {
          const el = this.el.querySelector('[data-cancel]');
          if (el) {
            window.liveSocket.execJS(el, el.getAttribute('data-cancel'));
          }
        }
      };
      
      document.addEventListener('mousedown', this.clickAwayHandler);
    }, 200);
  },
  
  destroyed() {
    if (this.clickAwayHandler) {
      document.removeEventListener('mousedown', this.clickAwayHandler);
    }
  }
}

export default DelayedModalClickAway
