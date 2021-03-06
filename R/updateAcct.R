#' Constructs the equity account calculations from the portfolio data and
#' corresponding close prices.
#' 
#' @param name  string identifying account
#' @param Dates Dates from which to calculate equity account
#' @export
updateAcct <- function(name='default', Dates=NULL) 
{ # @author Peter Carl

    Account<-getAccount(name)
    if(!is.null(attr(Account,'currency'))) {
        a.ccy.str<-attr(Account,'currency')
    } 

    Portfolios = names(Account$portfolios)
    
    if(is.null(Dates))
        Dates <- unique(do.call(c,c(lapply(Portfolios, function(x) index(.getPortfolio(x)$summary)), use.names=FALSE, recursive=FALSE)))[-1]
    # if all the portfolio summary tables only have one observation
    # then we haven't made any transactions, so there's nothing to update
    if(!length(Dates))
        return(name)
    
    #trim to only time prior to Dates
    whichi = NROW(Account$summary)
    if(last(index(Account$summary))>.parseISO8601(Dates)$first.time){
        whichi<-first(Account$summary[paste(.parseISO8601(Dates)$first.time,'::',sep=''), which.i = TRUE])
        if(!is.null(whichi)) whichi=whichi-1
        if(whichi<1) whichi=1 
        Account$summary = Account$summary[1:whichi,]
    }


    # Append the portfolio summary data to the portfolio slot
    for(pname in Portfolios){
        Portfolio = .getPortfolio(pname)
        if(!is.null(attr(Portfolio,'currency'))) {
            p.ccy.str<-attr(Portfolio,'currency')
        } 
        
        # Test whether portfolio and account are of the same ccy        
        psummary = Portfolio$summary[Dates]
        if( a.ccy.str != p.ccy.str ){
            # If not, translate the portfolio summary to the account currency
            CcyMult <- NA
            port_currency<-try(getInstrument(p.ccy.str), silent=TRUE)
            if(inherits(port_currency,"try-error") | !is.instrument(port_currency)){
                warning("Currency",p.ccy.str," not found, using currency multiplier of 1")
                CcyMult<-1
            } else {
                FXrate.str<-paste(p.ccy.str,a.ccy.str,sep='') # currency quote convention is EURUSD which reads as "USD per EUR"
                FXrate<-try(get(FXrate.str), silent=TRUE)
                #TODO FIXME: this uses convention to sort out the rate, we should check $currency and $counter_currency and make sure directionality is correct 
                invert=FALSE
                if(inherits(FXrate,"try-error")){
                    FXrate.str<-paste(a.ccy.str,p.ccy.str,sep='')
                    FXrate<-try(get(FXrate.str), silent=TRUE)
                    if(inherits(FXrate,"try-error")){ 
                        warning("Exchange Rate",FXrate.str," not found for symbol,',Symbol,' using currency multiplier of 1")
                        CcyMult<-1
                    } else {
                        invert=TRUE
                    }
                }
            }        
            if(is.na(CcyMult) && !is.na(FXrate)) {
                if(inherits(FXrate,'xts')){
                    CcyMult <- FXrate[Dates]
                    CcyMult <- na.locf(merge(CcyMult,index(psummary)))
                    CcyMult <- drop(CcyMult[index(psummary)])
                } else {
                    CcyMult<-as.numeric(FXrate)
                }
            } else {
                CcyMult<-1
            }
            if(isTRUE(invert)){
                # portfolio and instrument have different currencies, and FXrate was in the wrong direction
                CcyMult<-1/CcyMult
            }
            
            #multiply by the currency multiplier    
            psummary<-psummary*CcyMult
        }
        # now bind it
        Account$portfolios[[pname]] = rbind(Account$portfolios[[pname]][1:whichi,],psummary)
    }

    summary = NULL
    # get the dimensions we need to work with 
    ## TODO Find more efficient way to establish dimensions of the result
    table = .getByPortf(Account, 'Net.Trading.PL', Dates)
    obsLength = length(index(table))
    obsDates = index(table)
    if(obsLength > 1) # can't estimate periodicity of one observation
      on=periodicity(table)$units
    else
      on="none"

    # Now aggregate the portfolio information into the $summary slot
    Attributes = c('Additions', 'Withdrawals', 'Realized.PL', 'Unrealized.PL', 'Interest', 'Gross.Trading.PL', 'Txn.Fees', 'Net.Trading.PL', 'Advisory.Fees', 'Net.Performance', 'End.Eq')

    for(Attribute in Attributes) {
        switch(Attribute,
            Realized.PL = ,
            Unrealized.PL = ,
            Gross.Trading.PL = ,
            Txn.Fees = ,
            Net.Trading.PL = {
                table = .getByPortf(Account, Attribute, Dates)
                result = xts(rowSums(table,na.rm=TRUE),order.by=index(table))
            },
            Additions = {
                result = if(on=="none")
                  as.xts(sum(Account$Additions[obsDates]), order.by=index(table))
                else{
                  if(length(Account$Additions[obsDates])>0) # catch empty sets
                    period.apply(Account$Additions[obsDates], endpoints(Account$Additions[obsDates], on=on), sum) # aggregates multiple account txns 
                  else
                    xts(rep(0,obsLength),order.by=obsDates)
                }
            }, 
            Withdrawals = {
              result = if(on=="none")
                as.xts(sum(Account$Withdrawals[obsDates]), order.by=index(table))
              else{
                if(length(Account$Withdrawals[obsDates])>0) # catch empty sets
                  period.apply(Account$Withdrawals[obsDates], endpoints(Account$Withdrawals[obsDates], on=periodicity(table)$units), sum)
                else
                  xts(rep(0,obsLength),order.by=obsDates)
              }
            }, 
            Interest = {
              result = if(on=="none")
                as.xts(sum(Account$Interest[obsDates]), order.by=index(table))
              else{
                if(length(Account$Interest[obsDates])>0) # catch empty sets
                  period.apply(Account$Interest[obsDates], endpoints(Account$Interest[obsDates], on=periodicity(table)$units), sum)
                else
                  xts(rep(0,obsLength),order.by=obsDates)
              }
            },
            Advisory.Fees = ,
            Net.Performance = ,
            End.Eq = { 
                ## TODO no cash handling for now, add this in later, but for now, zeroes 
                result = xts(rep(0,obsLength),order.by=obsDates)
            }
        )
        
        colnames(result) = Attribute
        if(is.null(summary)) {summary=result}
        else {summary=cbind(summary,result)}
    }
    summary[is.na(summary)] <- 0 # replace any NA's with zero
    Account$summary <- rbind(Account$summary, summary)
    # This function does not calculate End.Eq 
    
    assign(paste("account",name,sep='.'),Account, envir=.blotter) 
    return(name) #not sure this is a good idea
}

###############################################################################
# Blotter: Tools for transaction-oriented trading systems development
# for R (see http://r-project.org/) 
# Copyright (c) 2008-2015 Peter Carl and Brian G. Peterson
#
# This library is distributed under the terms of the GNU Public License (GPL)
# for full details see the file COPYING
#
# $Id$
#
###############################################################################
